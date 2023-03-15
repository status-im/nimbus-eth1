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
  std/[algorithm, hashes, sequtils, sets, strutils, tables],
  eth/[common, p2p, trie/nibbles],
  stint,
  ../../range_desc,
  ./hexary_error

{.push raises: [].}

type
  HexaryPpFn* =
    proc(key: RepairKey): string {.gcsafe, raises: [CatchableError].}
      ## For testing/debugging: key pretty printer function

  ByteArray33* = array[33,byte]
    ## Used for 31 byte database keys, i.e. <marker> + <32-byte-key>

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
    TmpRoot                         ## Mutable root node

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
    root*: RepairKey                ## Root node needed when `path.len == 0`
    path*: seq[RPathStep]
    tail*: NibblesSeq               ## Stands for non completed leaf path

  XPathStep* = object
    ## Similar to `RPathStep` for an arbitrary (sort of transparent) trie
    key*: Blob                      ## Node hash implied by `node` data
    node*: XNodeObj
    nibble*: int8                   ## Branch node selector (if any)

  XPath* = object
    root*: NodeKey                  ## Root node needed when `path.len == 0`
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

  HexaryTreeDbRef* = ref object
    ## Hexary trie plus helper structures
    tab*: Table[RepairKey,RNodeRef] ## key-value trie table, in-memory db
    repairKeyGen*: uint64           ## Unique tmp key generator
    keyPp*: HexaryPpFn              ## For debugging, might go away

  HexaryGetFn* = proc(key: openArray[byte]): Blob
    {.gcsafe, raises: [CatchableError].}
      ## Persistent database `get()` function. For read-only cases, this
      ## function can be seen as the persistent alternative to ``tab[]` on
      ## a `HexaryTreeDbRef` descriptor.

  HexaryNodeReport* = object
    ## Return code for single node operations
    slot*: Option[int]              ## May refer to indexed argument slots
    kind*: Option[NodeKind]         ## Node type (if any)
    dangling*: seq[NodeSpecs]       ## Missing inner sub-tries
    error*: HexaryError             ## Error code, or `NothingSerious`

const
  EmptyNodeBlob* = seq[byte].default
  EmptyNibbleRange* = EmptyNodeBlob.initNibbleRange

static:
  # Not that there is no doubt about this ...
  doAssert NodeKey.default.ByteArray32.initNibbleRange.len == 64

var
  disablePrettyKeys* = false      ## Degugging, print raw keys if `true`

proc isNodeKey*(a: RepairKey): bool {.gcsafe.}
proc isZero*(a: RepairKey): bool {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc initImpl(key: var RepairKey; data: openArray[byte]): bool =
  key.reset
  if 0 < data.len and data.len <= 33:
    let trg = addr key.ByteArray33[33 - data.len]
    trg.copyMem(unsafeAddr data[0], data.len)
    return true


proc append(writer: var RlpWriter, node: RNodeRef) =
  ## Mixin for RLP writer
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


proc append(writer: var RlpWriter, node: XNodeObj) =
  ## Mixin for RLP writer
  case node.kind:
  of Branch:
    writer.append(node.bLink)
  of Extension:
    writer.startList(2)
    writer.append(node.ePfx.hexPrefixEncode(isleaf = false))
    writer.append(node.eLink)
  of Leaf:
    writer.startList(2)
    writer.append(node.lPfx.hexPrefixEncode(isleaf = true))
    writer.append(node.lData)

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc to*(key: NodeKey; T: type RepairKey): T {.gcsafe.}

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

proc ppImpl(key: RepairKey; db: HexaryTreeDbRef): string =
  if key.isZero:
    return "ø"
  if not key.isNodekey:
    var num: uint64
    (addr num).copyMem(unsafeAddr key.ByteArray33[25], 8)
    return "%" & $num
  try:
    if not disablePrettyKeys and not db.keyPp.isNil:
      return db.keyPp(key)
  except CatchableError:
    discard
  key.ByteArray33.toSeq.mapIt(it.toHex(2)).join.toLowerAscii

proc ppImpl(key: NodeKey; db: HexaryTreeDbRef): string =
  key.to(RepairKey).ppImpl(db)

proc ppImpl(w: openArray[RepairKey]; db: HexaryTreeDbRef): string =
  w.mapIt(it.ppImpl(db)).join(",")

proc ppImpl(w: openArray[Blob]; db: HexaryTreeDbRef): string =
  var q: seq[RepairKey]
  for a in w:
    var key: RepairKey
    discard key.initImpl(a)
    q.add key
  q.ppImpl(db)

proc ppStr(blob: Blob): string =
  if blob.len == 0: ""
  else: blob.mapIt(it.toHex(2)).join.toLowerAscii.ppImpl(hex = true)

proc ppImpl(n: RNodeRef; db: HexaryTreeDbRef): string =
  let so = n.state.ord
  case n.kind:
  of Leaf:
    ["l","ł","L","R"][so] & "(" & $n.lPfx & "," & n.lData.ppStr & ")"
  of Extension:
    ["e","€","E","R"][so] & "(" & $n.ePfx & "," & n.eLink.ppImpl(db) & ")"
  of Branch:
    ["b","þ","B","R"][so] & "(" & n.bLink.ppImpl(db) & "," & n.bData.ppStr & ")"

proc ppImpl(n: XNodeObj; db: HexaryTreeDbRef): string =
  case n.kind:
  of Leaf:
    "l(" & $n.lPfx & "," & n.lData.ppStr & ")"
  of Extension:
    var key: RepairKey
    discard key.initImpl(n.eLink)
    "e(" & $n.ePfx & "," & key.ppImpl(db) & ")"
  of Branch:
    "b(" & n.bLink[0..15].ppImpl(db) & "," &  n.bLink[16].ppStr & ")"

proc ppImpl(w: RPathStep; db: HexaryTreeDbRef): string =
  let
    nibble = if 0 <= w.nibble: w.nibble.toHex(1).toLowerAscii else: "ø"
    key = w.key.ppImpl(db)
  "(" & key & "," & nibble & "," & w.node.ppImpl(db) & ")"

proc ppImpl(w: XPathStep; db: HexaryTreeDbRef): string =
  let nibble = if 0 <= w.nibble: w.nibble.toHex(1).toLowerAscii else: "ø"
  var key: RepairKey
  discard key.initImpl(w.key)
  "(" & key.ppImpl(db) & "," & $nibble & "," & w.node.ppImpl(db) & ")"

proc ppImpl(db: HexaryTreeDbRef; root: NodeKey): seq[string] =
  ## Dump the entries from the a generic repair tree. This function assumes
  ## that mapped keys are printed `$###` if a node is locked or static, and
  ## some substitute for the first letter `$` otherwise (if they are mutable.)
  proc toKey(s: string): uint64 =
    try:
      result = s[1 ..< s.len].parseUint
    except ValueError as e:
      raiseAssert "Ooops ppImpl(s=" & s & "): name=" & $e.name & " msg=" & e.msg
    if s[0] != '$':
      result = result or (1u64 shl 63)
  proc cmpIt(x, y: (uint64,string)): int =
    cmp(x[0],y[0])

  var accu: seq[(uint64,string)]
  if root.ByteArray32 != ByteArray32.default:
    accu.add @[(0u64, "($0" & "," & root.ppImpl(db) & ")")]
  for key,node in db.tab.pairs:
    accu.add (
      key.ppImpl(db).tokey,
      "(" & key.ppImpl(db) & "," & node.ppImpl(db) & ")")

  accu.sorted(cmpIt).mapIt(it[1])

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc pp*(s: string; hex = false): string =
  ## For long strings print `begin..end` only
  s.ppImpl(hex)

proc pp*(w: NibblesSeq): string =
  $w

proc pp*(key: RepairKey): string =
  ## Raw key, for referenced key dump use `key.pp(db)` below
  key.ByteArray33.toSeq.mapIt(it.toHex(2)).join.tolowerAscii

proc pp*(key: NodeKey): string =
  ## Raw key, for referenced key dump use `key.pp(db)` below
  key.ByteArray32.toSeq.mapIt(it.toHex(2)).join.tolowerAscii

proc pp*(key: NodeKey|RepairKey; db: HexaryTreeDbRef): string =
  key.ppImpl(db)

proc pp*(
    w: RNodeRef|XNodeObj|RPathStep|XPathStep;
    db: HexaryTreeDbRef;
      ): string =
  w.ppImpl(db)

proc pp*(w:openArray[RPathStep|XPathStep];db:HexaryTreeDbRef;indent=4): string =
  w.toSeq.mapIt(it.ppImpl(db)).join(indent.toPfx)

proc pp*(w: RPath; db: HexaryTreeDbRef; indent=4): string =
  result = "<" & w.root.pp(db) & ">"
  if 0 < w.path.len:
    result &= indent.toPfx & w.path.pp(db,indent)
  result &= indent.toPfx & "(" & $w.tail & ")"

proc pp*(w: XPath; db: HexaryTreeDbRef; indent=4): string =
  result = "<" & w.root.pp(db) & ">"
  if 0 < w.path.len:
    result &= indent.toPfx & w.path.pp(db,indent)
  result &= indent.toPfx & "(" & $w.tail & "," & $w.depth & ")"

proc pp*(db: HexaryTreeDbRef; root: NodeKey; indent=4): string =
  ## Dump the entries from the a generic repair tree.
  db.ppImpl(root).join(indent.toPfx)

proc pp*(db: HexaryTreeDbRef; indent=4): string =
  ## varinat of `pp()` above
  db.ppImpl(NodeKey.default).join(indent.toPfx)

# ------------------------------------------------------------------------------
# Public constructor (or similar)
# ------------------------------------------------------------------------------

proc init*(key: var RepairKey; data: openArray[byte]): bool =
  key.initImpl(data)

proc newRepairKey*(db: HexaryTreeDbRef): RepairKey =
  db.repairKeyGen.inc
  # Storing in proper endian handy for debugging (but not really important)
  when cpuEndian == bigEndian:
    var src = db.repairKeyGen.toBytesBE
  else:
    var src = db.repairKeyGen.toBytesLE
  (addr result.ByteArray33[25]).copyMem(addr src[0], 8)
  result.ByteArray33[0] = 1

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hash*(a: RepairKey): Hash =
  ## Tables mixin
  a.ByteArray33.hash

proc `==`*(a, b: RepairKey): bool =
  ## Tables mixin
  a.ByteArray33 == b.ByteArray33

proc to*(key: NodeKey; T: type NibblesSeq): T =
  key.ByteArray32.initNibbleRange

proc to*(key: NodeKey; T: type RepairKey): T =
  (addr result.ByteArray33[1]).copyMem(unsafeAddr key.ByteArray32[0], 32)

proc isZero*(a: RepairKey): bool =
  a == typeof(a).default

proc isZero*[T: NodeTag|NodeKey](a: T): bool =
  a == typeof(a).default

proc isNodeKey*(a: RepairKey): bool =
  a.ByteArray33[0] == 0

proc convertTo*(data: Blob; T: type NodeKey): T =
  ## Probably lossy conversion, use `init()` for safe conversion
  discard result.init(data)

proc convertTo*(data: Blob; T: type NodeTag): T =
  ## Ditto for node tag
  data.convertTo(NodeKey).to(NodeTag)

proc convertTo*(data: Blob; T: type RepairKey): T =
  ## Probably lossy conversion, use `init()` for safe conversion
  discard result.initImpl(data)

proc convertTo*(node: RNodeRef; T: type Blob): T =
  ## Write the node as an RLP-encoded blob
  var writer = initRlpWriter()
  writer.append node
  writer.finish()

proc convertTo*(node: XNodeObj; T: type Blob): T =
  ## Variant of `convertTo()` for `XNodeObj` nodes.
  var writer = initRlpWriter()
  writer.append node
  writer.finish()

proc convertTo*(nodeList: openArray[XNodeObj]; T: type Blob): T =
  ## Variant of `convertTo()` for a list of `XNodeObj` nodes.
  var writer = initRlpList(nodeList.len)
  for w in nodeList:
    writer.append w
  writer.finish

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
