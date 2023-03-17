# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Find node paths in hexary tries.

{.push raises: [].}

import
  std/[algorithm, sequtils, sets, strutils, tables, times],
  chronos,
  eth/[common, trie/nibbles],
  stew/results,
  ../../range_desc,
  "."/[hexary_desc, hexary_error]

proc next*(path: XPath; getFn: HexaryGetFn; minDepth = 64): XPath
    {.gcsafe, raises: [CatchableError].}

proc prev*(path: XPath; getFn: HexaryGetFn; minDepth = 64): XPath
    {.gcsafe, raises: [CatchableError].}

# ------------------------------------------------------------------------------
# Private pretty printing helpers
# ------------------------------------------------------------------------------

proc asDateTime(m: Moment): DateTime =
  ## Approximate UTC based `DateTime` for a `Moment`
  let
    utcNow = times.now().utc
    momNow = Moment.now()
  utcNow + initDuration(nanoseconds = (m - momNow).nanoseconds)

# --------------

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
    discard key.init(a)
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
    discard key.init(n.eLink)
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
  discard key.init(w.key)
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
# Private helpers
# ------------------------------------------------------------------------------

proc getNibblesImpl(path: XPath; start = 0): NibblesSeq =
  ## Re-build the key path
  for n in start ..< path.path.len:
    let it = path.path[n]
    case it.node.kind:
    of Branch:
      result = result & @[it.nibble.byte].initNibbleRange.slice(1)
    of Extension:
      result = result & it.node.ePfx
    of Leaf:
      result = result & it.node.lPfx
  result = result & path.tail

proc getLeafData(path: XPath): Blob =
  ## Return the leaf data from a successful `XPath` computation (if any.)
  ## Note that this function also exists as `hexary_paths.leafData()` but
  ## the import of this file is avoided.
  if path.tail.len == 0 and 0 < path.path.len:
    let node = path.path[^1].node
    case node.kind:
    of Branch:
      return node.bLink[16]
    of Leaf:
      return node.lData
    of Extension:
      discard

proc toBranchNode(
    rlp: Rlp
      ): XNodeObj
      {.gcsafe, raises: [RlpError].} =
  var rlp = rlp
  XNodeObj(kind: Branch, bLink: rlp.read(array[17,Blob]))

proc toLeafNode(
    rlp: Rlp;
    pSegm: NibblesSeq
      ): XNodeObj
      {.gcsafe, raises: [RlpError].} =
  XNodeObj(kind: Leaf, lPfx: pSegm, lData: rlp.listElem(1).toBytes)

proc toExtensionNode(
    rlp: Rlp;
    pSegm: NibblesSeq
      ): XNodeObj
      {.gcsafe, raises: [RlpError].} =
  XNodeObj(kind: Extension, ePfx: pSegm, eLink: rlp.listElem(1).toBytes)


proc to(node: XNodeObj; T: type RNodeRef): T =
  case node.kind:
  of Leaf:
    result = T(
      kind: Leaf,
      lData: node.lData,
      lPfx: node.lPfx)
  of Extension:
    result = T(
      kind: Extension,
      eLink: node.eLink.convertTo(RepairKey),
      ePfx: node.ePfx)
  of Branch:
    result = T(
      kind: Branch,
      bData: node.bLink[16])
    for n in 0 .. 15:
      result.bLink[n] = node.bLink[n].convertTo(RepairKey)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc pathLeast(
    path: XPath;
    key: Blob;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [CatchableError].} =
  ## For the partial path given, extend by branch nodes with least node
  ## indices.
  result = path
  result.tail = EmptyNibbleRange
  result.depth = result.getNibblesImpl.len

  var
    key = key
    value = key.getFn()
  if value.len == 0:
    return

  while true:
    block loopContinue:
      let nodeRlp = rlpFromBytes value
      case nodeRlp.listLen:
      of 2:
        let (isLeaf,pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes

        # Leaf node
        if isLeaf:
          let node = nodeRlp.toLeafNode(pathSegment)
          result.path.add XPathStep(key: key, node: node, nibble: -1)
          result.depth += pathSegment.len
          return # done ok

        let node = nodeRlp.toExtensionNode(pathSegment)
        if 0 < node.eLink.len:
          value = node.eLink.getFn()
          if 0 < value.len:
            result.path.add XPathStep(key: key, node: node, nibble: -1)
            result.depth += pathSegment.len
            key = node.eLink
            break loopContinue
      of 17:
        # Branch node
        let node = nodeRlp.toBranchNode
        if node.bLink[16].len != 0 and 64 <= result.depth:
          result.path.add XPathStep(key: key, node: node, nibble: -1)
          return # done ok

        for inx in 0 .. 15:
          let newKey = node.bLink[inx]
          if 0 < newKey.len:
            value = newKey.getFn()
            if 0 < value.len:
              result.path.add XPathStep(key: key, node: node, nibble: inx.int8)
              result.depth.inc
              key = newKey
              break loopContinue
      else:
        discard

      # Recurse (iteratively)
      while true:
        block loopRecurse:
          # Modify last branch node and try again
          if result.path[^1].node.kind == Branch:
            for inx in result.path[^1].nibble+1 .. 15:
              let newKey = result.path[^1].node.bLink[inx]
              if 0 < newKey.len:
                value = newKey.getFn()
                if 0 < value.len:
                  result.path[^1].nibble = inx.int8
                  key = newKey
                  break loopContinue
          # Failed, step back and try predecessor branch.
          while path.path.len < result.path.len:
            case result.path[^1].node.kind:
            of Branch:
              result.depth.dec
              result.path.setLen(result.path.len - 1)
              break loopRecurse
            of Extension:
              result.depth -= result.path[^1].node.ePfx.len
              result.path.setLen(result.path.len - 1)
            of Leaf:
              return # Ooops
          return # Failed
      # Notreached
    # End while
  # Notreached


proc pathMost(
    path: XPath;
    key: Blob;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [CatchableError].} =
  ## For the partial path given, extend by branch nodes with greatest node
  ## indices.
  result = path
  result.tail = EmptyNibbleRange
  result.depth = result.getNibblesImpl.len

  var
    key = key
    value = key.getFn()
  if value.len == 0:
    return

  while true:
    block loopContinue:
      let nodeRlp = rlpFromBytes value
      case nodeRlp.listLen:
      of 2:
        let (isLeaf,pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes

        # Leaf node
        if isLeaf:
          let node = nodeRlp.toLeafNode(pathSegment)
          result.path.add XPathStep(key: key, node: node, nibble: -1)
          result.depth += pathSegment.len
          return # done ok

        # Extension node
        let node = nodeRlp.toExtensionNode(pathSegment)
        if 0 < node.eLink.len:
          value = node.eLink.getFn()
          if 0 < value.len:
            result.path.add XPathStep(key: key, node: node, nibble: -1)
            result.depth += pathSegment.len
            key = node.eLink
            break loopContinue
      of 17:
        # Branch node
        let node = nodeRlp.toBranchNode
        if node.bLink[16].len != 0 and 64 <= result.depth:
          result.path.add XPathStep(key: key, node: node, nibble: -1)
          return # done ok

        for inx in 15.countDown(0):
          let newKey = node.bLink[inx]
          if 0 < newKey.len:
            value = newKey.getFn()
            if 0 < value.len:
              result.path.add XPathStep(key: key, node: node, nibble: inx.int8)
              result.depth.inc
              key = newKey
              break loopContinue
      else:
        discard

      # Recurse (iteratively)
      while true:
        block loopRecurse:
          # Modify last branch node and try again
          if result.path[^1].node.kind == Branch:
            for inx in (result.path[^1].nibble-1).countDown(0):
              let newKey = result.path[^1].node.bLink[inx]
              if 0 < newKey.len:
                value = newKey.getFn()
                if 0 < value.len:
                  result.path[^1].nibble = inx.int8
                  key = newKey
                  break loopContinue
          # Failed, step back and try predecessor branch.
          while path.path.len < result.path.len:
            case result.path[^1].node.kind:
            of Branch:
              result.depth.dec
              result.path.setLen(result.path.len - 1)
              break loopRecurse
            of Extension:
              result.depth -= result.path[^1].node.ePfx.len
              result.path.setLen(result.path.len - 1)
            of Leaf:
              return # Ooops
          return # Failed
      # Notreached
    # End while
  # Notreached

# ---------------

proc fillFromLeft(
    db: HexaryTreeDbRef;       # Target in-memory database
    rootKey: NodeKey;          # State root for persistent source database
    getFn: HexaryGetFn;        # Source database abstraction
    maxLeafs = 5000;           # Error if more than this many leaf nodes
      ): Result[int,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Import persistent sub-tree into target database

  # Find first least path
  var
    here = XPath(root: rootKey).pathLeast(rootkey.to(Blob), getFn)
    countSteps = 0

  if 0 < here.path.len:
    while true:
      countSteps.inc

      # Import records
      for step in here.path:
        db.tab[step.key.convertTo(RepairKey)] = step.node.to(RNodeRef)

      # Get next path
      let topKey = here.path[^1].key
      here = here.next(getFn)

      # Check for end condition
      if here.path.len == 0:
        break
      if topKey == here.path[^1].key:
        return err(GarbledNextLeaf) # Ooops
      if maxLeafs <= countSteps:
        return err(LeafMaxExceeded)

  ok(countSteps)

proc fillFromRight(
    db: HexaryTreeDbRef;       # Target in-memory database
    rootKey: NodeKey;          # State root for persistent source database
    getFn: HexaryGetFn;        # Source database abstraction
    maxLeafs = 5000;           # Error if more than this many leaf nodes
      ): Result[int,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Import persistent sub-tree into target database

  # Find first least path
  var
    here = XPath(root: rootKey).pathMost(rootkey.to(Blob), getFn)
    countSteps = 0

  if 0 < here.path.len:
    while true:
      countSteps.inc

      # Import records
      for step in here.path:
        db.tab[step.key.convertTo(RepairKey)] = step.node.to(RNodeRef)

      # Get next path
      let topKey = here.path[^1].key
      here = here.prev(getFn)

      # Check for end condition
      if here.path.len == 0:
        break
      if topKey == here.path[^1].key:
        return err(GarbledNextLeaf) # Ooops
      if maxLeafs <= countSteps:
        return err(LeafMaxExceeded)

  ok(countSteps)

# ------------------------------------------------------------------------------
# Public functions, pretty printing
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

proc pp*(
    w: openArray[RPathStep|XPathStep];
    db:HexaryTreeDbRef;
    delim: string;
      ): string =
  w.toSeq.mapIt(it.ppImpl(db)).join(delim)

proc pp*(
    w: openArray[RPathStep|XPathStep];
    db: HexaryTreeDbRef;
    indent = 4;
      ): string =
  w.pp(db, indent.toPfx)

proc pp*(w: RPath|XPath; db: HexaryTreeDbRef; delim: string): string =
  result = "<" & w.root.pp(db) & ">"
  if 0 < w.path.len:
    result &= delim & w.path.pp(db, delim)
  result &= delim & "(" & $w.tail
  when typeof(w) is XPath:
    result &= "," & $w.depth
  result &= ")"

proc pp*(w: RPath|XPath; db: HexaryTreeDbRef; indent=4): string =
  w.pp(db, indent.toPfx)


proc pp*(db: HexaryTreeDbRef; root: NodeKey; delim: string): string =
  ## Dump the entries from the a generic accounts trie. These are
  ## key value pairs for
  ## ::
  ##   Branch:    ($1,b(<$2,$3,..,$17>,))
  ##   Extension: ($18,e(832b5e..06e697,$19))
  ##   Leaf:      ($20,l(cc9b5d..1c3b4,f84401..f9e5129d[#70]))
  ##
  ## where keys are typically represented as `$<id>` or `¶<id>` or `ø`
  ## depending on whether a key is final (`$<id>`), temporary (`¶<id>`)
  ## or unset/missing (`ø`).
  ##
  ## The node types are indicated by a letter after the first key before
  ## the round brackets
  ## ::
  ##   Branch:    'b', 'þ', or 'B'
  ##   Extension: 'e', '€', or 'E'
  ##   Leaf:      'l', 'ł', or 'L'
  ##
  ## Here a small letter indicates a `Static` node which was from the
  ## original `proofs` list, a capital letter indicates a `Mutable` node
  ## added on the fly which might need some change, and the decorated
  ## letters stand for `Locked` nodes which are like `Static` ones but
  ## added later (typically these nodes are update `Mutable` nodes.)
  ##
  ## Beware: dumping a large database is not recommended
  db.ppImpl(root).join(delim)

proc pp*(db: HexaryTreeDbRef; root: NodeKey; indent=4): string =
  ## Dump the entries from the a generic repair tree.
  db.pp(root, indent.toPfx)


proc pp*(m: Moment): string =
  ## Prints a moment in time similar to *chronicles* time format.
  m.asDateTime.format "yyyy-MM-dd HH:mm:ss'.'fff'+00:00'"

# ------------------------------------------------------------------------------
# Public functions, traversal over partial tree in persistent database
# ------------------------------------------------------------------------------

proc next*(
    path: XPath;
    getFn: HexaryGetFn;
    minDepth = 64;
      ): XPath
      {.gcsafe, raises: [CatchableError].} =
  ## Advance the argument `path` to the next leaf node (if any.). The
  ## `minDepth` argument requires the result of `next()` to satisfy
  ## `minDepth <= next().getNibbles.len`.
  var pLen = path.path.len

  # Find the last branch in the path, increase link and step down
  while 0 < pLen:

    # Find branch none
    pLen.dec

    let it = path.path[pLen]
    if it.node.kind == Branch and it.nibble < 15:

      # Find the next item to the right in the branch list
      for inx in (it.nibble + 1) .. 15:
        let link = it.node.bLink[inx]
        if link.len != 0:
          let
            branch = XPathStep(key: it.key, node: it.node, nibble: inx.int8)
            walk = path.path[0 ..< pLen] & branch
            newPath = XPath(root: path.root, path: walk).pathLeast(link, getFn)
          if minDepth <= newPath.depth and 0 < newPath.getLeafData.len:
            return newPath


proc prev*(
    path: XPath;
    getFn: HexaryGetFn;
    minDepth = 64;
      ): XPath
      {.gcsafe, raises: [CatchableError].} =
  ## Advance the argument `path` to the previous leaf node (if any.) The
  ## `minDepth` argument requires the result of `next()` to satisfy
  ## `minDepth <= next().getNibbles.len`.
  var pLen = path.path.len

  # Find the last branch in the path, decrease link and step down
  while 0 < pLen:

    # Find branch none
    pLen.dec
    let it = path.path[pLen]
    if it.node.kind == Branch and 0 < it.nibble:

      # Find the next item to the right in the branch list
      for inx in (it.nibble - 1).countDown(0):
        let link = it.node.bLink[inx]
        if link.len != 0:
          let
            branch = XPathStep(key: it.key, node: it.node, nibble: inx.int8)
            walk = path.path[0 ..< pLen] & branch
            newPath = XPath(root: path.root, path: walk).pathMost(link,getFn)
          if minDepth <= newPath.depth and 0 < newPath.getLeafData.len:
            return newPath


proc fromPersistent*(
    db: HexaryTreeDbRef;       # Target in-memory database
    rootKey: NodeKey;          # State root for persistent source database
    getFn: HexaryGetFn;        # Source database abstraction
    maxLeafs = 5000;           # Error if more than this many leaf nodes
    reverse = false;           # Fill left to right by default
      ): Result[int,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Import persistent sub-tree into target database
  if reverse:
    db.fillFromLeft(rootKey, getFn, maxLeafs)
  else:
    db.fillFromRight(rootKey, getFn, maxLeafs)

proc fromPersistent*(
    rootKey: NodeKey;          # State root for persistent source database
    getFn: HexaryGetFn;        # Source database abstraction
    maxLeafs = 5000;           # Error if more than this many leaf nodes
    reverse = false;           # Fill left to right by default
      ): Result[HexaryTreeDbRef,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Variant of `fromPersistent()` for an ad-hoc table
  let
    db = HexaryTreeDbRef()
    rc = db.fromPersistent(rootKey, getFn, maxLeafs, reverse)
  if rc.isErr:
    return err(rc.error)
  ok(db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
