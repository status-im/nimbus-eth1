# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

{.used.}

import
  std/[algorithm, hashes, tables,
       sequtils, streams, strformat, strutils, syncio, typetraits],
  pkg/[eth/common, eth/rlp, stew/byteutils, zlib],
  ../helpers,
  ./mpt_desc

type
  DebugTrieRef* = ref object of NodeTrieRef
    nodeId*: Table[NodeRef,uint]     ## `NodeKey` display map

  AccountRangeData* = tuple
    root: StateRoot
    start: Hash32
    pck: AccountRangePacket
    error: string
    lnr: int

const
  RootNode = "@"
  RegularNode = "$"
  MissingKeyNode = "%"
  StopNode = "#"
  SubRootNode = "^"
  OopsPfx = "!"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(node: NodeRef): Hash =
  hash cast[pointer](node)

proc getId(node: NodeRef, db: DebugTrieRef): uint =
  db.nodeId.withValue(node,val):
    return val[]
  result = (db.nodeId.len + 1).uint
  db.nodeId[node] = result

proc pfxStr(pfx: NibblesBuf): string =
  let
    p = $pfx
    w = if p.len <= 10: p
        else: p.substr(0,3) & ".." & p.substr(p.len-4)
  w & "#" & $p.len

proc sorted[T: NodeRef|StopNodeRef](
    nodes: openArray[T];
    db: DebugTrieRef;
      ): seq[T] =
  ## Sort by id
  proc nodeCmp(x,y: T): int =
    (x.getId db).cmp (y.getId db)
  nodes.sorted(nodeCmp)

proc forest(nodes: openArray[NodeRef], db: DebugTrieRef): seq[NodeRef] =
  ## Width first tree walk
  var batch = nodes.toSeq
  while 0 < batch.len:
    result &= batch
    var nextBatch: typeof batch
    for node in batch:
      case node.kind:
      of Branch:
        let w = BranchNodeRef(node)
        for n in 0 .. 15:
          if not w.brLinks[n].isNil and
             (w.brLinks[n].kind != Stop or
              not StopNodeRef(w.brLinks[n]).sub.isNil):
            nextBatch.add w.brLinks[n]
      of Stop:
        let w = StopNodeRef(node)
        if not w.sub.isNil:
          nextBatch.add w.sub
      of Leaf:
        discard
    batch.swap nextBatch

proc tree(node: NodeRef, db: DebugTrieRef): seq[NodeRef] =
  if not node.isNil:
    return @[node].forest(db)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc nodeIdStr(node: NodeRef, db: DebugTrieRef): string =
  if node.isNil:
    return "nil"
  if node == db.root:
    result &= RootNode
  elif node.kind != Stop:
    if node.selfKey.len == 0:
      result = MissingKeyNode
    else:
      result = RegularNode
  else:
    if node.selfKey.len == 0:
      result= OopsPfx
    if node.StopNodeRef.sub.isNil:
      result &= StopNode
    else:
      result &= SubRootNode
  result &= &"{node.getId(db):x}"

func keyStr(key: NodeKey): string =
  "<" & key.to(seq[byte]).toHex & "#" & $key.len & ">"

proc indStr(indent: int): string =
  if 0 < indent:
    return ' '.repeat(2 * indent)


proc nodeStr(node: NodeRef, db: DebugTrieRef): string =
  if node.isNil:
    result &= "(nil)"
    return
  result &= "(" & node.nodeIdStr(db) & ","

  case node.kind:
  of Branch:
    let w = BranchNodeRef(node)
    var q = newSeq[string](16)
    var nLinks = 0
    for n in 0 .. 15:
      if not w.brLinks[n].isNil:
        q[n] = w.brLinks[n].nodeIdStr(db)
        nLinks.inc

    if nLinks == 1 and not w.brLinks[0].isNil and 0 < w.xtPfx.len:
      # Pure extension node
      result &= (if 0 < node.selfKey.len: "e(" else: "E(")
      result &= w.xtPfx.pfxStr & "," & q[0]
    else:
      # Mixed mode
      if 0 < w.xtPfx.len:
        result &= w.xtPfx.pfxStr
      result &= "," & (if 0 < node.selfKey.len: "b(" else: "B(")
      result &= q.join(",")

  of Leaf:
    let w = LeafNodeRef(node)
    result &= (if 0 < node.selfKey.len: "l(" else: "L(")
    result &= w.lfPfx.pfxStr & ","
    #result &= w.lfPayload.toHex
    result &= "[" & $w.lfPayload.len & "]"

  of Stop:
    let w = StopNodeRef(node)
    result &= (if 0 < node.selfKey.len: "s(" else: "S(")
    if 0 < w.path.len:
      result &= w.path.pfxStr
    result &= ","
    if w.parent.isNil:
      result &= "nil"
    else:
      result &= w.parent.nodeIdStr(db)
    result &= ","
    if 0 <= w.inx:
      result &= $w.inx
    result &= ","
    if not w.sub.isNil:
      result &= w.sub.nodeIdStr(db)

  result &= "))"

proc nodesStr[T: NodeRef|StopNodeRef](
    nodes: openArray[T];
    db: DebugTrieRef;
    prefix: string;
    postfix: string;
      ): string =
  var n = 0
  for node in nodes:
    result &= prefix & node.nodeStr(db)
    n.inc
    if n < nodes.len:
      result &= postfix

# --------------

proc checkTreeImpl(
    node: NodeRef;
    path: NibblesBuf;
    db: DebugTrieRef;
      ): NibblesBuf =
  ## ..
  if path.len == 64:
    return path
  case node.kind:
  of Branch:
    let w = BranchNodeRef(node)
    if 63 <= path.len + w.xtPfx.len:
      return path
    let path = path & w.xtPfx
    var nLinks = 0
    for n in 0..15:
      if not w.brLinks[n].isNil:
        let
          q = path & NibblesBuf.nibble(byte n)
          p = w.brLinks[n].checkTreeImpl(q, db)
        if 0 < p.len:
          return p
        nLinks.inc
    if nLinks == 0:
      return path
    if 0 < w.xtPfx.len and nLinks == 1 and w.brLinks[0].isNil:
      return path
    # ok
  of Leaf:
    let w = LeafNodeRef(node)
    if path.len + w.lfPfx.len != 64:
      return path
    # ok
  of Stop:
    let w = StopNodeRef(node)
    if w.sub.isNil or (path.len != 0 and path.len != w.path.len):
      return w.path
    return w.sub.checkTreeImpl(w.path, db)

  # NibblesBuf() => ok

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc toStr*(a: AccBody): string =
  result = "("
  result &= $a.nonce & ","
  result &= $a.balance.to(float).toStr & ","
  if not a.storageRoot.isEmpty:
    result &= a.storageRoot.Hash32.toStr
  result &= ","
  if not a.codeHash.isEmpty:
    result &= a.codeHash.Hash32.toStr
  result &= ")"

proc toStr*(a: SnapAccount): string =
  result = "(" & a.accHash.toStr & "," & a.accBody.toStr & ")"

proc toStr*(a: ProofNode): string =
  a.distinctBase.toHex

proc toStr*(a: openArray[SnapAccount|ProofNode], indent=1): string =
  let
    prefix = indStr(indent)
    prefix1 = (if indent < 0: "" else: prefix & " ")
    postfix = (if indent < 0: "" else: "\n")
  result = "["
  for n in 0 ..< a.len:
    if 0 < n:
      result &= prefix1
    result &= a[n].toStr
    if n + 1 < a.len:
      result &= "," & postfix
  result &= "]"

func toStr*(key: NodeKey): string =
  key.keyStr

proc toStr*(node: NodeRef; db: DebugTrieRef): string =
  node.nodeStr(db)

proc dbStr*(node: NodeRef; db: DebugTrieRef; indent=1, stopsOk=false): string =
  let
    prefix = indStr(indent)
    prefix1 = (if indent < 0: "" else: prefix & " ")
    prefix2 = (if indent < 0: "" else: indStr indent+1)
    postfix = (if indent < 0: "" else: "\n")

  result = "(tree(" & node.nodeIdStr(db) & ")"

  if not node.isNil:
    result &= ":" & postfix & node.tree(db).nodesStr(db, prefix2, postfix)

  if 0 < db.stops.len and stopsOk:
    result &= "," & postfix
    result &= prefix1 & "stops:" & postfix
    result &= db.stops.values.toSeq.sorted(db).nodesStr(db, prefix2, postfix)

  result &= ")"

# ------------

proc updateNodeIds*(db: DebugTrieRef) =
  discard db.root.nodeIdStr(db)
  discard db.root.tree(db).nodesStr(db,"","")
  discard db.stops.values.toSeq.sorted(db).nodesStr(db,"","")

proc getSubTreeId*(node: StopNodeRef, db: DebugTrieRef): uint = node.getId(db)
proc toIdStr*(id: uint): string = &"0x{id:x}u"

proc getSubTreeIds*(db: DebugTrieRef): seq[uint] =
  db.stops.values.toSeq.mapIt(it.getSubTreeId(db)).sorted

proc toIdStr*(ids: seq[uint]): string =
  "[" & ids.mapIt(it.toIdStr()).join(",") & "]"

# ------------

proc check*(tree: StopNodeRef; db: DebugTrieRef): NibblesBuf =
  ## Returns empty path if ok.
  if not tree.isNil:
    return tree.checkTreeImpl(NibblesBuf(), db)

# ------------

func to*(db: NodeTrieRef, T: type DebugTrieRef): T =
  if not db.isNil:
    result = T(root: db.root, stops: db.stops)
    result.updateNodeIds()

# ------------------------------------------------------------------------------
# Public serialisation functions
# ------------------------------------------------------------------------------

proc dumpToFile*(
    fPath: string;
    root: StateRoot;
    start: Hash32;
    pck: AccountRangePacket;
      ): bool =
  let s =
    $Hash32(root) & "\n" &
    $start & "\n" &
    rlp.encode(pck).toHex & "\n" &
    "\n"
  try:
    var fd: File
    if fd.open(fPath, fmAppend):
      fd.write s
      fd.close()
      return true
  except IOError:
    discard

  # false


proc accountRangeFromFile*(
    fd: var File;
    fPath: string;
    lnr = 0;
      ): AccountRangeData =
  if fd.isNil and not fd.open(fPath, fmRead):
    result.error = "Cannot open file \"" & fPath & "\" for reading"
    return

  result.lnr = lnr
  try:
    var line = ""

    while line.len == 0 or line[0] == '#':
      if fd.endOfFile:
        result.error = "End of file"
        return
      result.lnr.inc
      line = fd.readLine
    result.root = StateRoot(Hash32.fromHex line)

    result.lnr.inc
    line = fd.readLine
    if line.len == 0:
      result.error = "Missing line: Hash32 value"
      return
    result.start = Hash32.fromHex line

    result.lnr.inc
    line = fd.readLine
    if line.len == 0:
      result.error = "Missing line: AccountRangePacket value"
      return
    result.pck = rlp.decode(line.hexToSeqByte, AccountRangePacket)

  except IOError as e:
    result.error = $e.name & "(" & e.msg & ")"
  except ValueError as e:
    result.error = $e.name & "(" & e.msg & ")"
  except RlpError as e:
    result.error = $e.name & "(" & e.msg & ")"


proc accountRangeFromUnzip*(gz: GUnzipRef; lnr=0): AccountRangeData =
  result.lnr = lnr
  try:
    var line = ""

    while line.len == 0 or line[0] == '#':
      if gz.atEnd:
        result.error = "End of file"
        return
      result.lnr.inc
      line = gz.nextLine.valueOr:
        result.error = "Read error: " & $error
        return
    result.root = StateRoot(Hash32.fromHex line)

    result.lnr.inc
    line = gz.nextLine.valueOr:
      result.error = "Read error: " & $error
      return
    if line.len == 0:
      result.error = "Missing line: Hash32 value"
      return
    result.start = Hash32.fromHex line

    result.lnr.inc
    line =  gz.nextLine.valueOr:
      result.error = "Read error: " & $error
      return
    if line.len == 0:
      result.error = "Missing line: AccountRangePacket value"
      return
    result.pck = rlp.decode(line.hexToSeqByte, AccountRangePacket)

  except OSError as e:
    result.error = $e.name & "(" & e.msg & ")"
  except IOError as e:
    result.error = $e.name & "(" & e.msg & ")"
  except ValueError as e:
    result.error = $e.name & "(" & e.msg & ")"
  except RlpError as e:
    result.error = $e.name & "(" & e.msg & ")"


proc initUnzip*(fPath: string): Result[(Stream,GUnzipRef),string] =
  var (stm,gz) = (Stream(nil),GUnzipRef(nil))
  stm = fPath.newFileStream fmRead
  if stm.isNil:
    return err("Cannot open \"" & fPath & "\" for reading")
  try:
    gz = GUnzipRef.init(stm).valueOr:
      stm.close()
      return err("Cannot initialise unzip for \"" & fPath & "\": " & $error)
  except IOError as e:
    return err($e.name & "(" & e.msg & ")")
  except OSError as e:
    return err($e.name & "(" & e.msg & ")")
  ok((stm,gz))
 
# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
