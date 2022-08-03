#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[algorithm, hashes, options, sequtils, sets, strutils, strformat, tables],
  chronos,
  eth/[common/eth_types, p2p, rlp],
  eth/trie/[db, nibbles, trie_defs],
  nimcrypto/keccak,
  stew/byteutils,
  stint,
  "../../.."/[db/storage_types, constants],
  "../.."/[protocol, types],
  ../range_desc

{.push raises: [Defect].}

logScope:
  topics = "snap-proof"

const
  BasicChainTrieEnabled = false # proof-of-concept code, currently unused
  BasicChainTrieDebugging = false

  RepairTreeDebugging = false


type
  AccountsDbError* = enum
    NothingSerious = 0
    AccountSmallerThanBase
    AccountsNotSrictlyIncreasing
    AccountRepairBlocked
    Rlp2Or17ListEntries
    RlpBlobExpected
    RlpBranchLinkExpected
    RlpEncoding
    RlpExtPathEncoding
    RlpNonEmptyBlobExpected
    BoundaryProofFailed

  ByteArray32* =
    array[32,byte]

  ByteArray33 =
    array[33,byte]

  NodeKey =               ## Internal DB record reference type
    distinct ByteArray32

  RepairKey =              ## Internal DB record, `byte & NodeKey`
    distinct ByteArray33

  RNodeKind = enum
    Branch
    Extension
    Leaf

  RNodeState = enum
    Static = 0                        ## Inserted as proof record
    Locked                            ## Like `Static`, only added on-the-fly
    Mutable                           ## Open for modification

  RNodeRef = ref object
    ## For building a temporary repair tree
    state: RNodeState                 ## `Static` if added as proof data
    case kind: RNodeKind
    of Leaf:
      lPfx: NibblesSeq                ## Portion of path segment
      lData: Blob
    of Extension:
      ePfx: NibblesSeq                ## Portion of path segment
      eLink: RepairKey                ## Single down link
    of Branch:
      bLink: array[16,RepairKey]      ## Down links
      bData: Blob

  RPathStep = object
    ## For constructing tree traversal `seq[RPathStep]` path
    key: RepairKey                   ## Tree label, node hash
    node: RNodeRef                   ## Referes to data record
    nibble: int8                     ## Branch node selector (if any)

  RPathXStep = object
    ## Extended `RPathStep` needed for `NodeKey` assignmant
    pos: int                         ## Some position into `seq[RPathStep]`
    step: RPathStep                  ## Modified copy of an `RPathStep`
    canLock: bool                    ## Can set `Locked` state

  RPath = object
    path: seq[RPathStep]
    tail: NibblesSeq                 ## Stands for non completed leaf path

  RAccount = object
    ## Temporarily stashed account data. Proper account records have non-empty
    ## payload. Records with empty payload are lower boundary records.
    tag: NodeTag                     ## Equivalent to account hash
    key: RepairKey                   ## Leaf hash into hexary repair table
    payload: Blob                    ## Data payload

  RepairTreeDB = object
    tab: Table[RepairKey,RNodeRef]   ## Repair table
    acc: seq[RAccount]               ## Accounts to appprove of
    repairKeyGen: uint64             ## Unique tmp key generator

  AccountsDbRef* = ref object
    db: TrieDatabaseRef              ## General database

  AccountsDbSessionRef* = ref object
    #dbTx: DbTransaction             ## TBD
    keyMap: Table[RepairKey,uint]    ## For debugging only (will go away)
    base: AccountsDbRef              ## Back reference to common parameters
    rootKey: NodeKey                 ## Current root node
    peer: Peer                       ## For log messages
    rnDB: RepairTreeDB               ## Repair database

const
  EmptyBlob = seq[byte].default
  EmptyNibbleRange = EmptyBlob.initNibbleRange

static:
  # Not that there is no doubt about this ...
  doAssert NodeKey.default.ByteArray32.initNibbleRange.len == 64

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(tag: NodeTag; T: type NodeKey): T =
  tag.UInt256.toBytesBE.T

proc to(key: NodeKey; T: type UInt256): T =
  T.fromBytesBE(key.ByteArray32)

proc to(key: NodeKey; T: type NodeTag): T =
  key.to(UInt256).T

proc to(h: Hash256; T: type NodeKey): T =
  h.data.T

proc to(key: NodeKey; T: type NibblesSeq): T =
  key.ByteArray32.initNibbleRange

proc to(key: NodeKey; T: type RepairKey): T =
  (addr result.ByteArray33[1]).copyMem(unsafeAddr key.ByteArray32[0], 32)

proc to(tag: NodeTag; T: type RepairKey): T =
  tag.to(NodeKey).to(RepairKey)

proc isZero[T: NodeTag|NodeKey|RepairKey](a: T): bool =
  a == T.default

proc `==`(a, b: NodeKey): bool =
  a.ByteArray32 == b.ByteArray32

proc `==`(a, b: RepairKey): bool =
  a.ByteArray33 == b.ByteArray33

proc hash(a: NodeKey): Hash =
  a.ByteArray32.hash

proc hash(a: RepairKey): Hash =
  a.ByteArray33.hash

proc digestTo(data: Blob; T: type NodeKey): T =
  keccak256.digest(data).data.T

proc isNodeKey(a: RepairKey): bool =
  a.ByteArray33[0] == 0

proc newRepairKey(ps: AccountsDbSessionRef): RepairKey =
  ps.rnDB.repairKeyGen.inc
  var src = ps.rnDB.repairKeyGen.toBytesBE
  (addr result.ByteArray33[25]).copyMem(addr src[0], 8)
  result.ByteArray33[0] = 1

proc init(key: var NodeKey; data: openArray[byte]): bool =
  key.reset
  if data.len <= 32:
    if 0 < data.len:
      let trg = addr key.ByteArray32[32 - data.len]
      trg.copyMem(unsafeAddr data[0], data.len)
    return true

proc dup(node: RNodeRef): RNodeRef =
  new result
  result[] = node[]

proc convertTo(data: openArray[byte]; T: type NodeKey): T =
  discard result.init(data)

proc convertTo(key: RepairKey; T: type NodeKey): T =
  if key.isNodeKey:
    discard result.init(key.ByteArray33[1 .. 32])

proc convertTo(node: RNodeRef; T: type Blob): T =
  var writer = initRlpWriter()

  proc appendOk(writer: var RlpWriter; key: RepairKey): bool =
    if key.isZero:
      writer.append(EmptyBlob)
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


template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

# ------------------------------------------------------------------------------
# Private getters & setters
# ------------------------------------------------------------------------------

proc xPfx(node: RNodeRef): NibblesSeq =
  case node.kind:
  of Leaf:
    return node.lPfx
  of Extension:
    return node.ePfx
  of Branch:
    doAssert node.kind != Branch # Ooops

proc `xPfx=`(node: RNodeRef, val: NibblesSeq) =
  case node.kind:
  of Leaf:
    node.lPfx = val
  of Extension:
    node.ePfx = val
  of Branch:
    doAssert node.kind != Branch # Ooops

proc xData(node: RNodeRef): Blob =
  case node.kind:
  of Branch:
    return node.bData
  of Leaf:
    return node.lData
  of Extension:
    doAssert node.kind != Extension # Ooops

proc `xData=`(node: RNodeRef; val: Blob) =
  case node.kind:
  of Branch:
    node.bData = val
  of Leaf:
    node.lData = val
  of Extension:
    doAssert node.kind != Extension # Ooops

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

template noPpError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

proc pp(s: string; hex = false): string =
  if hex:
    let n = (s.len + 1) div 2
    (if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. s.len-1]) &
      "[" & (if 0 < n: "#" & $n else: "") & "]"
  elif s.len <= 30:
    s
  else:
    (if (s.len and 1) == 0: s[0 ..< 8] else: "0" & s[0 ..< 7]) &
      "..(" & $s.len & ").." & s[s.len-16 ..< s.len]

proc pp(a: Hash256; collapse = true): string =
  if not collapse:
    a.data.mapIt(it.toHex(2)).join.toLowerAscii
  elif a == emptyRlpHash:
    "emptyRlpHash"
  elif a == blankStringHash:
    "blankStringHash"
  else:
    a.data.mapIt(it.toHex(2)).join[56 .. 63].toLowerAscii

proc pp(a: NodeKey; collapse = true): string =
  Hash256(data: a.ByteArray32).pp(collapse)

# ---------

proc toKey(a: RepairKey; ps: AccountsDbSessionRef): uint =
  if not a.isZero:
    noPpError("pp(RepairKey)"):
      if not ps.keyMap.hasKey(a):
        ps.keyMap[a] = ps.keyMap.len.uint + 1
      result = ps.keyMap[a]

proc toKey(a: NodeKey; ps: AccountsDbSessionRef): uint =
  a.to(RepairKey).toKey(ps)

proc toKey(a: NodeTag; ps: AccountsDbSessionRef): uint =
  a.to(NodeKey).toKey(ps)


proc pp(a: NodeKey; ps: AccountsDbSessionRef): string =
  if a.isZero: "ø" else:"$" & $a.toKey(ps)

proc pp(a: RepairKey; ps: AccountsDbSessionRef): string =
  if a.isZero: "ø" elif a.isNodeKey: "$" & $a.toKey(ps) else: "¶" & $a.toKey(ps)

proc pp(a: NodeTag; ps: AccountsDbSessionRef): string =
  a.to(NodeKey).pp(ps)

# ---------

proc pp(q: openArray[byte]; noHash = false): string =
  if q.len == 32 and not noHash:
    var a: array[32,byte]
    for n in 0..31: a[n] = q[n]
    ($Hash256(data: a)).pp
  else:
    q.toSeq.mapIt(it.toHex(2)).join.toLowerAscii.pp(hex = true)

proc pp(blob: Blob): string =
  blob.mapIt(it.toHex(2)).join

proc pp(a: Account): string =
  noPpError("pp(Account)"):
    result = &"({a.nonce},{a.balance},{a.storageRoot},{a.codeHash})"

proc pp(sa: SnapAccount): string =
  "(" & $sa.accHash & "," & sa.accBody.pp & ")"

proc pp(al: seq[SnapAccount]): string =
  result = "  @["
  noPpError("pp(seq[SnapAccount])"):
    for n,rec in al:
      result &= &"|    # <{n}>|    {rec.pp},"
  if 10 < result.len:
    result[^1] = ']'
  else:
    result &= "]"

proc pp(blobs: seq[Blob]): string =
  result = "  @["
  noPpError("pp(seq[Blob])"):
    for n,rec in blobs:
      result &= "|    # <" & $n & ">|    \"" & rec.pp & "\".hexToSeqByte,"
  if 10 < result.len:
    result[^1] = ']'
  else:
    result &= "]"

proc pp(branch: array[17,Blob]; ps: AccountsDbSessionRef): string =
  result = "["
  noPpError("pp(array[17,Blob])"):
    for a in 0 .. 15:
      result &= branch[a].convertTo(NodeKey).pp(ps) & ","
  result &= branch[16].pp & "]"

proc pp(branch: array[16,RepairKey]; ps: AccountsDbSessionRef): string =
  result = "["
  noPpError("pp(array[17,Blob])"):
    for a in 0 .. 15:
      result &= branch[a].pp(ps) & ","
  result[^1] = ']'

proc pp(hs: seq[NodeKey]; ps: AccountsDbSessionRef): string =
 "<" & hs.mapIt(it.pp(ps)).join(",") & ">"

proc pp(hs: HashSet[NodeKey]; ps: AccountsDbSessionRef): string =
  "{" &
    toSeq(hs.items).mapIt(it.toKey(ps)).sorted.mapIt("$" & $it).join(",") & "}"

proc pp(w: NibblesSeq): string =
  $w

proc pp(n: RNodeRef; ps: AccountsDbSessionRef): string =
  proc ppStr(blob: Blob): string =
    if blob.len == 0: "" else: blob.pp.pp(hex = true)
  noPpError("pp(RNodeRef)"):
    let so = n.state.ord
    case n.kind:
    of Leaf:
      result = ["l","ł","L"][so] & &"({n.lPfx.pp},{n.lData.ppStr})"
    of Extension:
      result = ["e","€","E"][so] & &"({n.ePfx.pp},{n.eLink.pp(ps)})"
    of Branch:
      result = ["b","þ","B"][so] & &"({n.bLink.pp(ps)},{n.bData.ppStr})"

proc pp(w: RPathStep; ps: AccountsDbSessionRef): string =
  noPpError("pp(seq[(NodeKey,RNodeRef)])"):
    let nibble = if 0 <= w.nibble: &"{w.nibble:x}" else: "ø"
    result = &"({w.key.pp(ps)},{nibble},{w.node.pp(ps)})"

proc pp(w: openArray[RPathStep]; ps: AccountsDbSessionRef; indent = 4): string =
  let pfx = "\n" & " ".repeat(indent)
  noPpError("pp(seq[(NodeKey,RNodeRef)])"):
    result = w.toSeq.mapIt(it.pp(ps)).join(pfx)

proc pp(w: RPath; ps: AccountsDbSessionRef; indent = 4): string =
  let pfx = "\n" & " ".repeat(indent)
  noPpError("pp(RPath)"):
    result = w.path.pp(ps,indent) & &"{pfx}({w.tail.pp})"

proc pp(w: RPathXStep; ps: AccountsDbSessionRef): string =
  noPpError("pp(seq[(int,RPathStep)])"):
    let y = if w.canLock: "lockOk" else: "noLock"
    result = &"({w.pos},{y},{w.step.pp(ps)})"

proc pp(w: seq[RPathXStep]; ps: AccountsDbSessionRef; indent = 4): string =
  let pfx = "\n" & " ".repeat(indent)
  noPpError("pp(seq[RPathXStep])"):
    result = w.mapIt(it.pp(ps)).join(pfx)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

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
#

proc hexaryImport(
    ps: AccountsDbSessionRef;
    recData: Blob
      ): Result[void,AccountsDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Decode a single trie item for adding to the table and add it to the
  ## database. Branch and exrension record links are collected.
  let
    nodeKey = recData.digestTo(NodeKey)
    repairKey = nodeKey.to(RepairKey) # for repair table
  var
    rlp = recData.rlpFromBytes
    blobs = newSeq[Blob](2)         # temporary, cache
    links: array[16,RepairKey]      # reconstruct branch node
    blob16: Blob                    # reconstruct branch node
    top = 0                         # count entries
    rNode: RNodeRef                 # repair tree node

  # Collect lists of either 2 or 17 blob entries.
  for w in rlp.items:
    case top
    of 0, 1:
      if not w.isBlob:
        return err(RlpBlobExpected)
      blobs[top] = rlp.read(Blob)
    of 2 .. 15:
      var key: NodeKey
      if not key.init(rlp.read(Blob)):
        return err(RlpBranchLinkExpected)
      # Update ref pool
      links[top] = key.to(RepairKey)
    of 16:
      if not w.isBlob:
        return err(RlpBlobExpected)
      blob16 = rlp.read(Blob)
    else:
      return err(Rlp2Or17ListEntries)
    top.inc

  # Verify extension data
  case top
  of 2:
    if blobs[0].len == 0:
      return err(RlpNonEmptyBlobExpected)
    let (isLeaf, pathSegment) = hexPrefixDecode blobs[0]
    if isLeaf:
      rNode = RNodeRef(
        kind:  Leaf,
        lPfx:  pathSegment,
        lData: blobs[1])
    else:
      var key: NodeKey
      if not key.init(blobs[1]):
        return err(RlpExtPathEncoding)
      # Update ref pool
      rNode = RNodeRef(
        kind:  Extension,
        ePfx:  pathSegment,
        eLink: key.to(RepairKey))
  of 17:
    for n in [0,1]:
      var key: NodeKey
      if not key.init(blobs[n]):
        return err(RlpBranchLinkExpected)
      # Update ref pool
      links[n] = key.to(RepairKey)
    rNode = RNodeRef(
      kind:  Branch,
      bLink: links,
      bData: blob16)
  else:
    discard

  # Add to repair database
  ps.rnDB.tab[repairKey] = rNode

  # Add to hexary trie database -- disabled, using bulk import later
  #ps.base.db.put(nodeKey.ByteArray32, recData)

  when RepairTreeDebugging:
    # Rebuild blob from repair record
    let nodeBlob = rNode.convertTo(Blob)
    if nodeBlob != recData:
      echo "*** hexaryImport oops:",
        " kind=", rNode.kind,
        " key=", repairKey.pp(ps),
        " nodeBlob=", nodeBlob.pp,
        " recData=", recData.pp
    doAssert nodeBlob == recData

  ok()

# ------------------------------------------------------------------------------
# Private functions, repair tree action helpers
# ------------------------------------------------------------------------------

proc rTreeExtendLeaf(
    ps: AccountsDbSessionRef;
    rPath: RPath;
    key: RepairKey
      ): RPath =
  ## Append a `Leaf` node to a `Branch` node (see `rTreeExtend()`.)
  if 0 < rPath.tail.len:
    let
      nibble = rPath.path[^1].nibble
      leaf = RNodeRef(
        state: Mutable,
        kind:  Leaf,
        lPfx:  rPath.tail)
    ps.rnDB.tab[key] = leaf
    if not key.isNodeKey:
      rPath.path[^1].node.bLink[nibble] = key
    return RPath(
      path: rPath.path & RPathStep(key: key, node: leaf, nibble: -1),
      tail: EmptyNibbleRange)

proc rTreeExtendLeaf(
    ps: AccountsDbSessionRef;
    rPath: RPath;
    key: RepairKey;
    node: RNodeRef
     ): RPath =
  ## Register `node` and append/link a `Leaf` node to a `Branch` node (see
  ## `rTreeExtend()`.)
  if 1 < rPath.tail.len and node.state == Mutable:
    let
      nibble = rPath.tail[0].int8
      xStep = RPathStep(key: key, node: node, nibble: nibble)
      xPath = RPath(path: rPath.path & xStep, tail: rPath.tail.slice(1))
    return ps.rTreeExtendLeaf(xPath, ps.newRepairKey())


proc rTreeSplitNode(
    ps: AccountsDbSessionRef;
    rPath: RPath;
    key: RepairKey;
    node: RNodeRef
     ): RPath =
  ## Replace `Leaf` or `Extension` node in tuple `(key,node)` by parts (see
  ## `rTreeExtend()`):
  ##
  ##   left(Extension) -> middle(Branch) -> right(Extension or Leaf)
  ##     ^                  ^
  ##     |                  |
  ##   added-to-path      added-to-path
  ##
  ## where either `left()` or `right()` extensions might be missing.
  ##
  let
    nibbles = node.xPfx
    lLen = rPath.tail.sharedPrefixLen(nibbles)
  if nibbles.len == 0 or rPath.tail.len <= lLen:
    return # Ooops      (^^^^^ otherwise `rPath` was not the longest)
  var
    mKey = key
  let
    mNibble = nibbles[lLen]           # exists as `lLen < tail.len`
    rPfx = nibbles.slice(lLen + 1)    # might be empty OK

  result = rPath

  # Insert node (if any): left(Extension)
  if 0 < lLen:
    let lNode = RNodeRef(
      state: Mutable,
      kind:  Extension,
      ePfx:  result.tail.slice(0,lLen),
      eLink: ps.newRepairKey())
    ps.rnDB.tab[key] = lNode
    result.path.add RPathStep(key: key, node: lNode, nibble: -1)
    result.tail = result.tail.slice(lLen)
    mKey = lNode.eLink

  # Insert node: middle(Branch)
  let mNode = RNodeRef(
    state: Mutable,
    kind:  Branch)
  ps.rnDB.tab[mKey] = mNode
  result.path.add RPathStep(key: mKey, node: mNode, nibble: -1) # no nibble yet

  # Insert node (if any): right(Extension) -- not to be registered in `rPath`
  if 0 < rPfx.len:
    let rKey = ps.newRepairKey()
    # Re-use argument node
    mNode.bLink[mNibble] = rKey
    ps.rnDB.tab[rKey] = node
    node.xPfx = rPfx
  # Otherwise merge argument node
  elif node.kind == Extension:
    mNode.bLink[mNibble] = node.eLink
  else:
    # Oops, does it make sense, at all?
    mNode.bData = node.lData

# ------------------------------------------------------------------------------
# Private functions, repair tree actions
# ------------------------------------------------------------------------------

proc rTreeFollow(nodeKey: NodeKey; ps: AccountsDbSessionRef): RPath =
  ## Compute logest possible path matching the `nodeKey` nibbles.
  result.tail = nodeKey.to(NibblesSeq)
  noKeyError("rTreeFollow"):
    var key = ps.rootKey.to(RepairKey)
    while ps.rnDB.tab.hasKey(key) and 0 < result.tail.len:
      let node = ps.rnDB.tab[key]
      case node.kind:
      of Leaf:
        if result.tail.len == result.tail.sharedPrefixLen(node.lPfx):
          # Bingo, got full path
          result.path.add RPathStep(key: key, node: node, nibble: -1)
          result.tail = EmptyNibbleRange
        return
      of Branch:
        let nibble = result.tail[0].int8
        if node.bLink[nibble].isZero:
          return
        result.path.add RPathStep(key: key, node: node, nibble: nibble)
        result.tail = result.tail.slice(1)
        key = node.bLink[nibble]
      of Extension:
        if node.ePfx.len != result.tail.sharedPrefixLen(node.ePfx):
          return
        result.path.add RPathStep(key: key, node: node, nibble: -1)
        result.tail = result.tail.slice(node.ePfx.len)
        key = node.eLink

proc rTreeFollow(nodeTag: NodeTag; ps: AccountsDbSessionRef): RPath =
  ## Variant of `rTreeFollow()`
  nodeTag.to(NodeKey).rTreeFollow(ps)


proc rTreeInterpolate(rPath: RPath; ps: AccountsDbSessionRef): RPath =
  ## Extend path, add missing nodes to tree. The last node added will be
  ## a `Leaf` node if this function succeeds.
  ##
  ## The function assumed that the `RPath` argument is the longest possible
  ## as just constructed by `rTreeFollow()`
  if 0 < rPath.path.len and 0 < rPath.tail.len:
    noKeyError("rTreeExtend"):
      let step = rPath.path[^1]
      case step.node.kind:
      of Branch:
        # Now, the slot must not be empty. An empty slot would lead to a
        # rejection of this record as last valid step, contrary to the
        # assumption `path` is the longest one.
        if step.nibble < 0:
          return # sanitary check failed
        let key = step.node.bLink[step.nibble]
        if key.isZero:
          return # sanitary check failed

        # Case: unused slot => add leaf record
        if not ps.rnDB.tab.hasKey(key):
          return ps.rTreeExtendLeaf(rPath, key)

        # So a `child` node exits but it is something that could not be used to
        # extend the argument `path` which is assumed the longest possible one.
        let child = ps.rnDB.tab[key]
        case child.kind:
        of Branch:
          # So a `Leaf` node can be linked into the `child` branch
          return ps.rTreeExtendLeaf(rPath, key, child)

        # Need to split the right `grandChild` in `child -> grandChild`
        # into parts:
        #
        #   left(Extension) -> middle(Branch)
        #                         |   |
        #                         |   +-----> right(Extension or Leaf) ...
        #                         +---------> new Leaf record
        #
        # where either `left()` or `right()` extensions might be missing
        of Extension, Leaf:
          var xPath = ps.rTreeSplitNode(rPath, key, child)
          if 0 < xPath.path.len:
            # Append `Leaf` node
            xPath.path[^1].nibble = xPath.tail[0].int8
            xPath.tail = xPath.tail.slice(1)
            return ps.rTreeExtendLeaf(xPath, ps.newRepairKey())
      of Leaf:
        return # Oops
      of Extension:
        let key = step.node.eLink

        var child: RNodeRef
        if ps.rnDB.tab.hasKey(key):
          child = ps.rnDB.tab[key]
          # `Extension` can only be followed by a `Branch` node
          if child.kind != Branch:
            return
        else:
          # Case: unused slot => add `Branch` and `Leaf` record
          child = RNodeRef(
            state: Mutable,
            kind:  Branch)
          ps.rnDB.tab[key] = child

        # So a `Leaf` node can be linked into the `child` branch
        return ps.rTreeExtendLeaf(rPath, key, child)


proc rTreeInterpolate(
    rPath: RPath;
    ps: AccountsDbSessionRef;
    payload: Blob
      ): RPath =
  ## Variant of `rTreeExtend()` which completes a `Leaf` record.
  result = rPath.rTreeInterpolate(ps)
  if 0 < result.path.len and result.tail.len == 0:
    let node = result.path[^1].node
    if node.kind != Extension and node.state == Mutable:
      node.xData = payload


proc rTreeUpdateKeys(rPath: RPath; ps: AccountsDbSessionRef): Result[void,int] =
  ## The argument `rPath` is assumed to organise database nodes as
  ##
  ##    root -> ... -> () -> () -> ... -> () -> () ...
  ##     |-------------|     |------------|      |------
  ##      static nodes        locked nodes        mutable nodes
  ##
  ## Where
  ## * Static nodes are read-only nodes provided by the proof database
  ## * Locked nodes are added read-only nodes that satisfy the proof condition
  ## * Mutable nodes are incomplete nodes
  ##
  ## Then update nodes from the right end and set all the mutable nodes
  ## locked if possible.
  var
    rTop = rPath.path.len
    stack: seq[RPathXStep]

  if 0 < rTop and
     rPath.path[^1].node.state == Mutable and
     rPath.path[0].node.state != Mutable:

    # Set `Leaf` entry
    let leafNode = rPath.path[^1].node.dup
    stack.add RPathXStep(
      pos: rTop - 1,
      canLock: true,
      step: RPathStep(
        node: leafNode,
        key: leafNode.convertTo(Blob).digestTo(NodeKey).to(RepairKey),
        nibble: -1))

    while true:
      rTop.dec

      # Update parent node (note that `2 <= rPath.path.len`)
      let
        thisKey = stack[^1].step.key
        preStep = rPath.path[rTop-1]
        preNibble = preStep.nibble

      # End reached
      if preStep.node.state != Mutable:

        # Verify the tail matches
        var key = RepairKey.default
        case preStep.node.kind:
        of Branch:
          key = preStep.node.bLink[preNibble]
        of Extension:
          key = preStep.node.eLink
        of Leaf:
          discard
        if key != thisKey:
          return err(rTop-1)

        when RepairTreeDebugging:
          echo "*** rTreeUpdateKeys",
             " rPath\n    ", rPath.pp(ps),
             "\n    stack\n    ", stack.pp(ps)

        # Ok, replace database records by stack entries
        var lockOk = true
        for n in countDown(stack.len-1,0):
          let item = stack[n]
          ps.rnDB.tab.del(rPath.path[item.pos].key)
          ps.rnDB.tab[item.step.key] = item.step.node
          if lockOk:
            if item.canLock:
              item.step.node.state = Locked
            else:
              lockOk = false
        if not lockOk:
          return err(rTop-1) # repeat
        break # Done ok()

      stack.add RPathXStep(
        pos: rTop - 1,
        step: RPathStep(
          node: preStep.node.dup, # (!)
          nibble: preNibble,
          key: preStep.key))

      case stack[^1].step.node.kind:
      of Branch:
        stack[^1].step.node.bLink[preNibble] = thisKey
        # Check whether all keys are proper, non-temporary keys
        stack[^1].canLock = true
        for n in 0 ..< 16:
          if not stack[^1].step.node.bLink[n].isNodeKey:
            stack[^1].canLock = false
            break
      of Extension:
        stack[^1].step.node.eLink = thisKey
        stack[^1].canLock = thisKey.isNodeKey
      of Leaf:
        return err(rTop-1)

      # Must not overwrite a non-temprary key
      if stack[^1].canLock:
        stack[^1].step.key =
          stack[^1].step.node.convertTo(Blob).digestTo(NodeKey).to(RepairKey)

  ok()

# ------------------------------------------------------------------------------
# Private walk along hexary trie records
# ------------------------------------------------------------------------------

when BasicChainTrieEnabled:
  proc hexaryFollow(
      ps: AccountsDbSessionRef;
      root: NodeKey;
      path: NibblesSeq
        ): (int, bool, Blob)
        {.gcsafe, raises: [Defect,RlpError]} =
    ## Returns the number of matching digits/nibbles from the argument `path`
    ## found in the proofs trie.
    let
      nNibbles = path.len
    var
      inPath = path
      recKey = root.ByteArray32.toSeq
      leafBlob: Blob
      emptyRef = false

    when BasicChainTrieDebugging:
      trace "follow", rootKey=root.pp(ps), path

    while true:
      let value = ps.base.db.get(recKey)
      if value.len == 0:
        break

      var nodeRlp = rlpFromBytes value
      case nodeRlp.listLen:
      of 2:
        let
          (isLeaf, pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
          sharedNibbles = inPath.sharedPrefixLen(pathSegment)
          fullPath = sharedNibbles == pathSegment.len
          inPathLen = inPath.len
        inPath = inPath.slice(sharedNibbles)

        # Leaf node
        if isLeaf:
          let leafMode = sharedNibbles == inPathLen
          if fullPath and leafMode:
            leafBlob = nodeRlp.listElem(1).toBytes
          when BasicChainTrieDebugging:
            let nibblesLeft = inPathLen - sharedNibbles
            trace "follow leaf",
              fullPath, leafMode, sharedNibbles, nibblesLeft,
              pathSegment, newPath=inPath
          break

        # Extension node
        if fullPath:
          let branch = nodeRlp.listElem(1)
          if branch.isEmpty:
            when BasicChainTrieDebugging:
              trace "follow extension", newKey="n/a"
            emptyRef = true
            break
          recKey = branch.toBytes
          when BasicChainTrieDebugging:
            trace "follow extension",
              newKey=recKey.convertTo(NodeKey).pp(ps), newPath=inPath
        else:
          when BasicChainTrieDebugging:
            trace "follow extension",
              fullPath, sharedNibbles, pathSegment,
              inPathLen, newPath=inPath
          break

      of 17:
        # Branch node
        if inPath.len == 0:
          leafBlob = nodeRlp.listElem(1).toBytes
          break
        let
          inx = inPath[0].int
          branch = nodeRlp.listElem(inx)
        if branch.isEmpty:
          when BasicChainTrieDebugging:
            trace "follow branch", newKey="n/a"
          emptyRef = true
          break
        inPath = inPath.slice(1)
        recKey = branch.toBytes
        when BasicChainTrieDebugging:
          trace "follow branch",
            newKey=recKey.convertTo(NodeKey).pp(ps), inx, newPath=inPath

      else:
        when BasicChainTrieDebugging:
          trace "follow oops",
            nColumns = nodeRlp.listLen
        break

    # end while

    let pathLen = nNibbles - inPath.len

    when BasicChainTrieDebugging:
      trace "follow done",
        recKey, emptyRef, pathLen, leafSize=leafBlob.len

    (pathLen, emptyRef, leafBlob)


  proc hexaryFollow(
      ps: AccountsDbSessionRef;
      root: NodeKey;
      path: NodeKey
        ): (int, bool, Blob)
        {.gcsafe, raises: [Defect,RlpError]} =
    ## Variant of `hexaryFollow()`
    ps.hexaryFollow(root, path.to(NibblesSeq))

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type AccountsDbRef;
    db: TrieDatabaseRef
      ): T =
  ## Main object constructor
  T(db: db)

proc init*(
    T: type AccountsDbSessionRef;
    pv: AccountsDbRef;
    root: Hash256;
    peer: Peer = nil
      ): T =
  ## Start a new session, do some actions an then discard the session
  ## descriptor (probably after commiting data.)
  AccountsDbSessionRef(base: pv, peer: peer, rootKey: root.to(NodeKey))

# ------------------------------------------------------------------------------
# Public functions, session related
# ------------------------------------------------------------------------------

proc merge*(
    ps: AccountsDbSessionRef;
    proof: SnapAccountProof
      ): Result[void,AccountsDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Import account proof records (as received with the snap message
  ## `AccountRange`) into the hexary trie of the repair database. These hexary
  ## trie records can be extended to a full trie at a later stage and used for
  ## validating account data.
  for n,rlpRec in proof:
    let rc = ps.hexaryImport(rlpRec)
    if rc.isErr:
      trace "merge(SnapAccountProof)", peer=ps.peer,
        proofs=ps.rnDB.tab.len, accounts=ps.rnDB.acc.len, error=rc.error
      return err(rc.error)

  ok()


proc merge*(
    ps: AccountsDbSessionRef;
    base: NodeTag;
    acc: seq[SnapAccount];
      ): Result[void,AccountsDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Import account records (as received with the snap message `AccountRange`)
  ## into the accounts list of the repair database. The accounts, together
  ## with some hexary trie records for proof can be used for validating
  ## the argument account data.
  ##
  if acc.len != 0:
    #if ps.rnDB.acc.len == 0 or ps.rnDB.acc[^1].tag <= base:
    # return ps.mergeImpl(base, acc)

    let
      prependOk = 0 < ps.rnDB.acc.len and base < ps.rnDB.acc[^1].tag
      saveLen = ps.rnDB.acc.len
      accTag0 = acc[0].accHash.to(NodeTag)

      # For error logging
      (peer, proofs, accounts) = (ps.peer, ps.rnDB.tab.len, ps.rnDB.acc.len)

    var
      error = NothingSerious
      saveQ: seq[RAccount]
    if prependOk:
      # Prepend `acc` argument before `ps.rnDB.acc`
      saveQ = ps.rnDB.acc

    block collectAccounts:
      # Verify lower bound
      if acc[0].accHash.to(NodeTag) < base:
        error = AccountSmallerThanBase
        trace "merge(seq[SnapAccount])", peer, proofs, base, accounts, error
        break collectAccounts

      # Add base for the records (no payload). Note that the assumption
      # holds: `ps.rnDB.acc[^1].tag <= base`
      if base < accTag0:
        ps.rnDB.acc.add RAccount(tag: base)

      # Check for the case that accounts are appended
      elif 0 < ps.rnDB.acc.len and accTag0 <= ps.rnDB.acc[^1].tag:
        error = AccountsNotSrictlyIncreasing
        trace "merge(seq[SnapAccount])", peer, proofs, base, accounts, error
        break collectAccounts

      # Add first account
      ps.rnDB.acc.add RAccount(tag: accTag0, payload: acc[0].accBody.encode)

      # Veify & add other accounts
      for n in 1 ..< acc.len:
        let nodeTag = acc[n].accHash.to(NodeTag)

        if nodeTag <= ps.rnDB.acc[^1].tag:
          # Recover accounts list and return error
          ps.rnDB.acc.setLen(saveLen)

          error = AccountsNotSrictlyIncreasing
          trace "merge(seq[SnapAccount])", peer, proofs, base, accounts, error
          break collectAccounts

        ps.rnDB.acc.add RAccount(tag: nodeTag, payload: acc[n].accBody.encode)

      # End block `collectAccounts`

    if prependOk:
      if error == NothingSerious:
        ps.rnDB.acc = ps.rnDB.acc & saveQ
      else:
        ps.rnDB.acc = saveQ

    if error != NothingSerious:
      return err(error)

  ok()


proc interpolate*(ps: AccountsDbSessionRef): Result[void,AccountsDbError] =
  ## Verifiy accounts by interpolating the collected accounts on the hexary
  ## trie of the repair database. If all accounts can be represented in the
  ## hexary trie, they are vonsidered validated.
  ##
  ## Note:
  ##   This function temporary and proof-of-concept. for production purposes,
  ##   it must be replaced by the new facility of the upcoming re-factored
  ##   database layer.
  ##
  # Walk top down and insert/complete missing account access nodes
  for n in countDown(ps.rnDB.acc.len-1,0):
    let acc = ps.rnDB.acc[n]
    if acc.payload.len != 0:
      let rPath = acc.tag.rTreeFollow(ps)
      var repairKey = acc.key
      if repairKey.isZero and 0 < rPath.path.len and rPath.tail.len == 0:
        repairKey = rPath.path[^1].key
        ps.rnDB.acc[n].key = repairKey
      if repairKey.isZero:
        let
          update = rPath.rTreeInterpolate(ps, acc.payload)
          final = acc.tag.rTreeFollow(ps)
        if update != final:
          return err(AccountRepairBlocked)
        ps.rnDB.acc[n].key = rPath.path[^1].key

  # Replace temporary repair keys by proper hash based node keys.
  var reVisit: seq[NodeTag]
  for n in countDown(ps.rnDB.acc.len-1,0):
    let acc = ps.rnDB.acc[n]
    if not acc.key.isZero:
      let rPath = acc.tag.rTreeFollow(ps)
      if rPath.path[^1].node.state == Mutable:
        let rc = rPath.rTreeUpdateKeys(ps)
        if rc.isErr:
          reVisit.add acc.tag

  while 0 < reVisit.len:
    var again: seq[NodeTag]
    for nodeTag in reVisit:
      let rc = nodeTag.rTreeFollow(ps).rTreeUpdateKeys(ps)
      if rc.isErr:
        again.add nodeTag
    if reVisit.len <= again.len:
      return err(BoundaryProofFailed)
    reVisit = again

  ok()

proc nHexaryRecords*(ps: AccountsDbSessionRef): int  =
  ## Number of hexary record entries in the session database.
  ps.rnDB.tab.len

proc nAccountRecords*(ps: AccountsDbSessionRef): int  =
  ## Number of account records in the session database. This number includes
  ## lower bound entries (which are not accoiunts, strictly speaking.)
  ps.rnDB.acc.len

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc importAccounts*(
    pv: AccountsDbRef;
    peer: Peer,      ## for log messages
    root: Hash256;  ## state root
    base: NodeTag;   ## before or at first account entry in `data`
    data: SnapAccountRange
      ): Result[void,AccountsDbError] =
  ## Validate and accounts and proofs (as received with the snap message
  ## `AccountRange`). This function combines the functionality of the `merge()`
  ## and the `interpolate()` functions.
  ##
  ## At a later stage, that function also will bulk-import the accounts into
  ## the block chain database
  ##
  ## Note that the `peer` argument is for log messages, only.
  let ps = AccountsDbSessionRef.init(pv, root, peer)
  try:
    block:
      let rc = ps.merge(data.proof)
      if rc.isErr:
        return err(rc.error)
    block:
      let rc = ps.merge(base, data.accounts)
      if rc.isErr:
        return err(rc.error)
  except RlpError:
    return err(RlpEncoding)

  block:
    ## Note:
    ##   `interpolate()` is a temporary proof-of-concept function. For
    ##   production purposes, it must be replaced by the new facility of
    ##   the upcoming re-factored database layer.
    let rc = ps.interpolate()
    if rc.isErr:
      return err(rc.error)

  # TODO: bulk import
  # ...

  trace "Accounts and proofs ok", peer, root=root.data.toHex,
    proof=data.proof.len, base, accounts=data.accounts.len
  ok()

# ------------------------------------------------------------------------------
# Debugging
# ------------------------------------------------------------------------------

proc assignPrettyKeys*(ps: AccountsDbSessionRef) =
  ## Prepare foe pretty pringing/debugging. Run early enough this function
  ## sets the root key to `"$"`, for instance.
  noPpError("validate(1)"):
    # Make keys assigned in pretty order for printing
    var keysList = toSeq(ps.rnDB.tab.keys)
    let rootKey = ps.rootKey.to(RepairKey)
    discard rootKey.toKey(ps)
    if ps.rnDB.tab.hasKey(rootKey):
      keysList = @[rootKey] & keysList
    for key in keysList:
      let node = ps.rnDB.tab[key]
      discard key.toKey(ps)
      case node.kind:
      of Branch: (for w in node.bLink: discard w.toKey(ps))
      of Extension: discard node.eLink.toKey(ps)
      of Leaf: discard

proc dumpPath*(ps: AccountsDbSessionRef; key: NodeTag): seq[string] =
  ## Pretty print helper compiling the path into the repair tree for the
  ## argument `key`.
  let rPath = key.rTreeFollow(ps)
  rPath.path.mapIt(it.pp(ps)) & @["(" & rPath.tail.pp & ")"]

proc dumpProofsDB*(ps: AccountsDbSessionRef): seq[string] =
  ## Dump the entries from the repair tree.
  var accu = @[(0u, "($0" & "," & ps.rootKey.pp(ps) & ")")]
  for key,node in ps.rnDB.tab.pairs:
    accu.add (key.toKey(ps), "(" & key.pp(ps) & "," & node.pp(ps) & ")")
  proc cmpIt(x, y: (uint,string)): int =
    cmp(x[0],y[0])
  result = accu.sorted(cmpIt).mapIt(it[1])

# ---------

proc dumpRoot*(root: Hash256; name = "snapRoot*"): string =
  noPpError("dumpRoot"):
    result = "import\n"
    result &= "  eth/common/eth_types,\n"
    result &= "  nimcrypto/hash,\n"
    result &= "  stew/byteutils\n\n"
    result &= "const\n"
    result &= &"  {name} =\n"
    result &= &"    \"{root.pp(false)}\".toDigest\n"

proc dumpSnapAccountRange*(
    base: NodeTag;
    data: SnapAccountRange;
    name = "snapData*"
      ): string =
  noPpError("dumpSnapAccountRange"):
    result = &"  {name} = ("
    result &= &"\n    \"{base.to(Hash256).pp(false)}\".toDigest,"
    result &= "\n    @["
    let accPfx = "\n      "
    for n in 0 ..< data.accounts.len:
      let
        hash = data.accounts[n].accHash
        body = data.accounts[n].accBody
      if 0 < n:
        result &= accPfx
      result &= &"# <{n}>"
      result &= &"{accPfx}(\"{hash.pp(false)}\".toDigest,"
      result &= &"{accPfx} {body.nonce}u64,"
      result &= &"{accPfx} \"{body.balance}\".parse(Uint256),"
      result &= &"{accPfx} \"{body.storageRoot.pp(false)}\".toDigest,"
      result &= &"{accPfx} \"{body.codehash.pp(false)}\".toDigest),"
    if result[^1] == ',':
      result[^1] = ']'
    else:
      result &= "]"
    result &= ",\n    @["
    let blobPfx = "\n      "
    for n in 0 ..< data.proof.len:
      let blob = data.proof[n]
      if 0 < n:
        result &= blobPfx
      result &= &"# <{n}>"
      result &= &"{blobPfx}\"{blob.pp}\".hexToSeqByte,"
    if result[^1] == ',':
      result[^1] = ']'
    else:
      result &= "]"
    result &= ")\n"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
