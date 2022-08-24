# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[hashes, sequtils, strutils, tables],
  eth/[common/eth_types, p2p, trie/nibbles],
  nimcrypto/keccak,
  stint,
  ../../range_desc

{.push raises: [Defect].}

type
  HexaryPpFn* = proc(key: RepairKey): string {.gcsafe.}
    ## For testing/debugging: key pretty printer function

  ByteArray32* = array[32,byte]
    ## Used for 32 byte database keys

  ByteArray33* = array[33,byte]
    ## Used for 31 byte database keys, i.e. <marker> + <32-byte-key>

  NodeKey* = distinct ByteArray32
    ## Hash key without the hash wrapper

  RepairKey* = distinct ByteArray33
    ## Byte prefixed `NodeKey` for internal DB records

  # Example trie from https://eth.wiki/en/fundamentals/patricia-tree
  #
  #   lookup data:
  #     "do":    "verb"
  #     "dog":   "puppy"
  #     "dodge": "coin"
  #     "horse": "stallion"
  #
  #   trie DB:
  #     root: [16 A]
  #     A:    [* * * * B * * * [20+"orse" "stallion"] * * * * * * *  *]
  #     B:    [00+"o" D]
  #     D:    [* * * * * * E * * * * * * * * *  "verb"]
  #     E:    [17 [* * * * * * [35 "coin"] * * * * * * * * * "puppy"]]
  #
  #     with first nibble of two-column rows:
  #       hex bits | node type  length
  #       ---------+------------------
  #        0  0000 | extension   even
  #        1  0001 | extension   odd
  #        2  0010 | leaf        even
  #        3  0011 | leaf        odd
  #
  #    and key path:
  #        "do":     6 4 6 f
  #        "dog":    6 4 6 f 6 7
  #        "dodge":  6 4 6 f 6 7 6 5
  #        "horse":  6 8 6 f 7 2 7 3 6 5

  NodeKind* = enum
    Branch
    Extension
    Leaf

  RNodeState* = enum
    Static = 0                      ## Inserted as proof record
    Locked                          ## Like `Static`, only added on-the-fly
    Mutable                         ## Open for modification

  RNodeRef* = ref object
    ## Node for building a temporary hexary trie coined `repair tree`.
    state*: RNodeState              ## `Static` if added from proof data set
    case kind*: NodeKind
    of Leaf:
      lPfx*: NibblesSeq             ## Portion of path segment
      lData*: Blob
    of Extension:
      ePfx*: NibblesSeq             ## Portion of path segment
      eLink*: RepairKey             ## Single down link
    of Branch:
      bLink*: array[16,RepairKey]   ## Down links
      #
      # Paraphrased comment from Andri's `stateless/readme.md` file in chapter
      # `Deviation from yellow paper`, (also found here
      #      github.com/status-im/nimbus-eth1
      #         /tree/master/stateless#deviation-from-yellow-paper)
      # [..] In the Yellow Paper, the 17th elem of the branch node can contain
      # a value. But it is always empty in a real Ethereum state trie. The
      # block witness spec also ignores this 17th elem when encoding or
      # decoding a branch node. This can happen because in a Ethereum secure
      # hexary trie, every keys have uniform length of 32 bytes or 64 nibbles.
      # With the absence of the 17th element, a branch node will never contain
      # a leaf value.
      bData*: Blob

  XNodeObj* = object
    ## Simplified version of `RNodeRef` to be used as a node for `XPathStep`
    case kind*: NodeKind
    of Leaf:
      lPfx*: NibblesSeq             ## Portion of path segment
      lData*: Blob
    of Extension:
      ePfx*: NibblesSeq             ## Portion of path segment
      eLink*: Blob                  ## Single down link
    of Branch:
      bLink*: array[17,Blob]        ## Down links followed by data

  RPathStep* = object
    ## For constructing a repair tree traversal path `RPath`
    key*: RepairKey                 ## Tree label, node hash
    node*: RNodeRef                 ## Referes to data record
    nibble*: int8                   ## Branch node selector (if any)

  RPath* = object
    path*: seq[RPathStep]
    tail*: NibblesSeq               ## Stands for non completed leaf path

  XPathStep* = object
    ## Similar to `RPathStep` for an arbitrary (sort of transparent) trie
    key*: Blob                      ## Node hash implied by `node` data
    node*: XNodeObj
    nibble*: int8                   ## Branch node selector (if any)

  XPath* = object
    path*: seq[XPathStep]
    tail*: NibblesSeq               ## Stands for non completed leaf path
    depth*: int                     ## May indicate path length (typically 64)

  RLeafSpecs* = object
    ## Temporarily stashed leaf data (as for an account.) Proper records
    ## have non-empty payload. Records with empty payload are administrative
    ## items, e.g. lower boundary records.
    pathTag*: NodeTag               ## Equivalent to account hash
    nodeKey*: RepairKey             ## Leaf hash into hexary repair table
    payload*: Blob                  ## Data payload

  HexaryTreeDB* = object
    rootKey*: NodeKey               ## Current root node
    tab*: Table[RepairKey,RNodeRef] ## Repair table
    acc*: seq[RLeafSpecs]           ## Accounts to appprove of
    repairKeyGen*: uint64           ## Unique tmp key generator
    keyPp*: HexaryPpFn              ## For debugging

const
  EmptyNodeBlob* = seq[byte].default
  EmptyNibbleRange* = EmptyNodeBlob.initNibbleRange

static:
  # Not that there is no doubt about this ...
  doAssert NodeKey.default.ByteArray32.initNibbleRange.len == 64

var
  disablePrettyKeys* = false        ## Degugging, pint raw keys if `true`

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc initImpl(key: var RepairKey; data: openArray[byte]): bool =
  key.reset
  if data.len <= 33:
    if 0 < data.len:
      let trg = addr key.ByteArray33[33 - data.len]
      trg.copyMem(unsafeAddr data[0], data.len)
    return true

proc initImpl(key: var NodeKey; data: openArray[byte]): bool =
  key.reset
  if data.len <= 32:
    if 0 < data.len:
      let trg = addr key.ByteArray32[32 - data.len]
      trg.copyMem(unsafeAddr data[0], data.len)
    return true

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc toPfx(indent: int): string =
  "\n" & " ".repeat(indent)

proc ppImpl(s: string; hex = false): string =
  ## For long strings print `begin..end` only
  if hex:
    let n = (s.len + 1) div 2
    (if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. s.len-1]) &
      "[" & (if 0 < n: "#" & $n else: "") & "]"
  elif s.len <= 30:
    s
  else:
    (if (s.len and 1) == 0: s[0 ..< 8] else: "0" & s[0 ..< 7]) &
      "..(" & $s.len & ").." & s[s.len-16 ..< s.len]

proc ppImpl(key: RepairKey; db: HexaryTreeDB): string =
  try:
    if not disablePrettyKeys and not db.keyPp.isNil:
      return db.keyPp(key)
  except:
    discard
  key.ByteArray33.toSeq.mapIt(it.toHex(2)).join.toLowerAscii

proc ppImpl(w: openArray[RepairKey]; db: HexaryTreeDB): string =
  w.mapIt(it.ppImpl(db)).join(",")

proc ppImpl(w: openArray[Blob]; db: HexaryTreeDB): string =
  var q: seq[RepairKey]
  for a in w:
    var key: RepairKey
    discard key.initImpl(a)
    q.add key
  q.ppImpl(db)

proc ppStr(blob: Blob): string =
  if blob.len == 0: ""
  else: blob.mapIt(it.toHex(2)).join.toLowerAscii.ppImpl(hex = true)

proc ppImpl(n: RNodeRef; db: HexaryTreeDB): string =
  let so = n.state.ord
  case n.kind:
  of Leaf:
    ["l","ł","L"][so] & "(" & $n.lPfx & "," & n.lData.ppStr & ")"
  of Extension:
    ["e","€","E"][so] & "(" & $n.ePfx & "," & n.eLink.ppImpl(db) & ")"
  of Branch:
    ["b","þ","B"][so] & "(" & n.bLink.ppImpl(db) & "," & n.bData.ppStr & ")"

proc ppImpl(n: XNodeObj; db: HexaryTreeDB): string =
  case n.kind:
  of Leaf:
    "l(" & $n.lPfx & "," & n.lData.ppStr & ")"
  of Extension:
    var key: RepairKey
    discard key.initImpl(n.eLink)
    "e(" & $n.ePfx & "," & key.ppImpl(db) & ")"
  of Branch:
    "b(" & n.bLink[0..15].ppImpl(db) & "," &  n.bLink[16].ppStr & ")"

proc ppImpl(w: RPathStep; db: HexaryTreeDB): string =
  let
    nibble = if 0 <= w.nibble: w.nibble.toHex(1).toLowerAscii else: "ø"
    key = w.key.ppImpl(db)
  "(" & key & "," & nibble & "," & w.node.ppImpl(db) & ")"

proc ppImpl(w: XPathStep; db: HexaryTreeDB): string =
  let nibble = if 0 <= w.nibble: w.nibble.toHex(1).toLowerAscii else: "ø"
  var key: RepairKey
  discard key.initImpl(w.key)
  "(" & key.ppImpl(db) & "," & $nibble & "," & w.node.ppImpl(db) & ")"

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc pp*(s: string; hex = false): string =
  ## For long strings print `begin..end` only
  s.ppImpl(hex)

proc pp*(w: NibblesSeq): string =
  $w

proc pp*(key: RepairKey; db: HexaryTreeDB): string =
  key.ppImpl(db)

proc pp*(w: RNodeRef|XNodeObj|RPathStep; db: HexaryTreeDB): string =
  w.ppImpl(db)

proc pp*(w:openArray[RPathStep|XPathStep]; db:HexaryTreeDB; indent=4): string =
  w.toSeq.mapIt(it.ppImpl(db)).join(indent.toPfx)

proc pp*(w: RPath; db: HexaryTreeDB; indent=4): string =
  w.path.pp(db,indent) & indent.toPfx & "(" & $w.tail & ")"

proc pp*(w: XPath; db: HexaryTreeDB; indent=4): string =
  w.path.pp(db,indent) & indent.toPfx & "(" & $w.tail & "," & $w.depth & ")"

# ------------------------------------------------------------------------------
# Public constructor (or similar)
# ------------------------------------------------------------------------------

proc init*(key: var NodeKey; data: openArray[byte]): bool =
  key.initImpl(data)

proc init*(key: var RepairKey; data: openArray[byte]): bool =
  key.initImpl(data)

proc newRepairKey*(db: var HexaryTreeDB): RepairKey =
  db.repairKeyGen.inc
  var src = db.repairKeyGen.toBytesBE
  (addr result.ByteArray33[25]).copyMem(addr src[0], 8)
  result.ByteArray33[0] = 1

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hash*(a: NodeKey): Hash =
  ## Tables mixin
  a.ByteArray32.hash

proc hash*(a: RepairKey): Hash =
  ## Tables mixin
  a.ByteArray33.hash

proc `==`*(a, b: NodeKey): bool =
  ## Tables mixin
  a.ByteArray32 == b.ByteArray32

proc `==`*(a, b: RepairKey): bool =
  ## Tables mixin
  a.ByteArray33 == b.ByteArray33

proc to*(tag: NodeTag; T: type NodeKey): T =
  tag.UInt256.toBytesBE.T

proc to*(key: NodeKey; T: type NibblesSeq): T =
  key.ByteArray32.initNibbleRange

proc to*(key: NodeKey; T: type RepairKey): T =
  (addr result.ByteArray33[1]).copyMem(unsafeAddr key.ByteArray32[0], 32)

proc isZero*[T: NodeTag|NodeKey|RepairKey](a: T): bool =
  a == T.default

proc isNodeKey*(a: RepairKey): bool =
  a.ByteArray33[0] == 0

proc digestTo*(data: Blob; T: type NodeKey): T =
  keccak256.digest(data).data.T

proc convertTo*[W: NodeKey|RepairKey](data: Blob; T: type W): T =
  ## Probably lossy conversion, use `init()` for safe conversion
  discard result.init(data)

proc convertTo*(node: RNodeRef; T: type Blob): T =
  ## Write the node as an RLP-encoded blob
  var writer = initRlpWriter()

  proc appendOk(writer: var RlpWriter; key: RepairKey): bool =
    if key.isZero:
      writer.append(EmptyNodeBlob)
    elif key.isNodeKey:
      var hash: Hash256
      (addr hash.data[0]).copyMem(unsafeAddr key.ByteArray33[1], 32)
      writer.append(hash)
    else:
      return false
    true

  case node.kind:
  of Branch:
    writer.startList(17)
    for n in 0 ..< 16:
      if not writer.appendOk(node.bLink[n]):
        return # empty `Blob`
    writer.append(node.bData)
  of Extension:
    writer.startList(2)
    writer.append(node.ePfx.hexPrefixEncode(isleaf = false))
    if not writer.appendOk(node.eLink):
      return # empty `Blob`
  of Leaf:
    writer.startList(2)
    writer.append(node.lPfx.hexPrefixEncode(isleaf = true))
    writer.append(node.lData)

  writer.finish()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
