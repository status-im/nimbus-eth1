# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[algorithm, sequtils, sets, strutils, tables],
  eth/[common, trie/nibbles],
  stew/byteutils,
  "."/[aristo_constants, aristo_desc, aristo_hike, aristo_init, aristo_vid],
  ./aristo_init/[aristo_memory, aristo_rocksdb]

# ------------------------------------------------------------------------------
# Ptivate functions
# ------------------------------------------------------------------------------

proc sortedKeys(lTab: Table[LeafTie,VertexID]): seq[LeafTie] =
  lTab.keys.toSeq.sorted(cmp = proc(a,b: LeafTie): int = cmp(a,b))

proc sortedKeys(kMap: Table[VertexID,HashLabel]): seq[VertexID] =
  kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID)

proc sortedKeys(sTab: Table[VertexID,VertexRef]): seq[VertexID] =
  sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID)

proc sortedKeys(pPrf: HashSet[VertexID]): seq[VertexID] =
  pPrf.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID)

proc toPfx(indent: int; offset = 0): string =
  if 0 < indent+offset: "\n" & " ".repeat(indent+offset) else: ""

proc labelVidUpdate(db: var AristoDb, lbl: HashLabel, vid: VertexID): string =
  if lbl.key.isValid and vid.isValid:
    if not db.top.isNil:
      let lblVid = db.top.pAmk.getOrVoid lbl
      if lblVid.isValid:
        if lblVid != vid:
          result = "(!)"
        return
    block:
      let lblVid = db.xMap.getOrVoid lbl
      if lblVid.isValid:
        if lblVid != vid:
          result = "(!)"
        return
    db.xMap[lbl] = vid

proc squeeze(s: string; hex = false; ignLen = false): string =
  ## For long strings print `begin..end` only
  if hex:
    let n = (s.len + 1) div 2
    result = if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. ^1]
    if not ignLen:
      result &= "[" & (if 0 < n: "#" & $n else: "") & "]"
  elif s.len <= 30:
    result = s
  else:
    result = if (s.len and 1) == 0: s[0 ..< 8] else: "0" & s[0 ..< 7]
    if not ignLen:
      result &= "..(" & $s.len & ")"
    result &= ".." & s[s.len-16 .. ^1]

proc stripZeros(a: string): string =
  a.strip(leading=true, trailing=false, chars={'0'}).toLowerAscii

proc ppVid(vid: VertexID; pfx = true): string =
  if pfx:
    result = "$"
  if vid.isValid:
    result &= vid.uint64.toHex.stripZeros.toLowerAscii
  else:
    result &= "ø"

proc vidCode(lbl: HashLabel, db: AristoDb): uint64 =
  if lbl.isValid:
    if not db.top.isNil:
      let vid = db.top.pAmk.getOrVoid lbl
      if vid.isValid:
        return vid.uint64
    block:
      let vid = db.xMap.getOrVoid lbl
      if vid.isValid:
        return vid.uint64

proc ppKey(key: HashKey): string =
  if key == HashKey.default:
    return "£ø"
  if key == VOID_HASH_KEY:
    return "£r"
  if key == VOID_CODE_KEY:
    return "£c"

  "%" & key.ByteArray32
           .mapIt(it.toHex(2)).join.tolowerAscii
           .squeeze(hex=true,ignLen=true)

proc ppLabel(lbl: HashLabel; db: AristoDb): string =
  if lbl.key == HashKey.default:
    return "£ø"
  if lbl.key == VOID_HASH_KEY:
    return "£r"
  if lbl.key == VOID_CODE_KEY:
    return "£c"
  
  let rid = if not lbl.root.isValid: "ø:"
            else: ($lbl.root.uint64.toHex).stripZeros & ":"
  if not db.top.isNil:
    let vid = db.top.pAmk.getOrVoid lbl
    if vid.isValid:
      return "£" & rid & vid.ppVid(pfx=false)
  block:
    let vid = db.xMap.getOrVoid lbl
    if vid.isValid:
      return "£" & rid & vid.ppVid(pfx=false)

  "%" & rid & lbl.key.ByteArray32
                     .mapIt(it.toHex(2)).join.tolowerAscii
                     .squeeze(hex=true,ignLen=true)

proc ppRootKey(a: HashKey): string =
  if a.isValid:
    return a.ppKey

proc ppCodeKey(a: HashKey): string =
  if a != VOID_CODE_KEY:
    return a.ppKey

proc ppLeafTie(lty: LeafTie, db: AristoDb): string =
  if not db.top.isNil:
    let vid =  db.top.lTab.getOrVoid lty
    if vid.isValid:
      return "@" & vid.ppVid

  "@" & ($lty.root.uint64.toHex).stripZeros & ":" &
    lty.path.to(HashKey).ByteArray32
            .mapIt(it.toHex(2)).join.squeeze(hex=true,ignLen=true)

proc ppPathPfx(pfx: NibblesSeq): string =
  let s = $pfx
  if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. ^1] & ":" & $s.len

proc ppNibble(n: int8): string =
  if n < 0: "ø" elif n < 10: $n else: n.toHex(1).toLowerAscii

proc ppPayload(p: PayloadRef, db: AristoDb): string =
  if p.isNil:
    result = "n/a"
  else:
    case p.pType:
    of BlobData:
      result &= p.blob.toHex.squeeze(hex=true)
    of AccountData:
      result = "("
      result &= $p.account.nonce & ","
      result &= $p.account.balance & ","
      result &= p.account.storageRoot.to(HashKey).ppRootKey() & ","
      result &= p.account.codeHash.to(HashKey).ppCodeKey() & ")"

proc ppVtx(nd: VertexRef, db: AristoDb, vid: VertexID): string =
  if not nd.isValid:
    result = "n/a"
  else:
    if db.top.isNil or not vid.isValid or vid in db.top.pPrf:
      result = ["L(", "X(", "B("][nd.vType.ord]
    elif vid in db.top.kMap:
      result = ["l(", "x(", "b("][nd.vType.ord]
    else:
      result = ["ł(", "€(", "þ("][nd.vType.ord]
    case nd.vType:
    of Leaf:
      result &= nd.lPfx.ppPathPfx & "," & nd.lData.ppPayload(db)
    of Extension:
      result &= nd.ePfx.ppPathPfx & "," & nd.eVid.ppVid
    of Branch:
      for n in 0..15:
        if nd.bVid[n].isValid:
          result &= nd.bVid[n].ppVid
        if n < 15:
          result &= ","
    result &= ")"

proc ppXMap*(
    db: AristoDb;
    kMap: Table[VertexID,HashLabel];
    pAmk: Table[HashLabel,VertexID];
    indent: int;
      ): string =

  let
    pfx = indent.toPfx(1)
    dups = pAmk.values.toSeq.toCountTable.pairs.toSeq
               .filterIt(1 < it[1]).toTable
    revOnly = pAmk.pairs.toSeq.filterIt(not kMap.hasKey it[1])
                        .mapIt((it[1],it[0])).toTable

  proc ppNtry(n: uint64): string =
    var s = VertexID(n).ppVid
    let lbl = kMap.getOrVoid VertexID(n)
    if lbl.isValid:
      let vid = pAmk.getOrVoid lbl
      if not vid.isValid:
        s = "(" & s & "," & lbl.ppLabel(db) & ",ø"
      elif vid != VertexID(n):
        s = "(" & s & "," & lbl.ppLabel(db) & "," & vid.ppVid
      let count = dups.getOrDefault(VertexID(n), 0)
      if 0 < count:
        if s[0] != '(':
          s &= "(" & s
        s &= ",*" & $count
    else:
      s &= "£r(!)"
    if s[0] == '(':
      s &= ")"
    s & ","

  result = "{"
  # Extra reverse lookups
  let revKeys = revOnly.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID)
  if 0 < revKeys.len:
    proc ppRevlabel(vid: VertexID): string =
      "(ø," & revOnly.getOrVoid(vid).ppLabel(db) & ")"
    var (i, r) = (0, revKeys[0])
    result &= revKeys[0].ppRevlabel
    for n in 1 ..< revKeys.len:
      let vid = revKeys[n]
      r.inc
      if r != vid:
        if i+1 != n:
          result &= ".. " & revKeys[n-1].ppRevlabel
        result &= pfx & vid.ppRevlabel
        (i, r) = (n, vid)
    if i < revKeys.len - 1:
      if i+1 != revKeys.len - 1:
        result &= ".. "
      else:
        result &= pfx
      result &= revKeys[^1].ppRevlabel

  # Forward lookups
  var cache: seq[(uint64,uint64,bool)]
  for vid in kMap.sortedKeys:
    let lbl = kMap.getOrVoid vid
    if lbl.isValid:
      cache.add (vid.uint64, lbl.vidCode(db), 0 < dups.getOrDefault(vid, 0))
      let lblVid = pAmk.getOrDefault(lbl, VertexID(0))
      if lblVid != VertexID(0) and lblVid != vid:
        cache[^1][2] = true
    else:
      cache.add (vid.uint64, 0u64, true)

  if 0 < cache.len:
    var (i, r) = (0, cache[0])
    if 0 < revKeys.len:
      result &= pfx
    result &= cache[i][0].ppNtry
    for n in 1 ..< cache.len:
      let w = cache[n]
      r[0].inc
      r[1].inc
      if r != w or w[2]:
        if i+1 != n:
          result &= ".. " & cache[n-1][0].ppNtry
        result &= pfx & cache[n][0].ppNtry
        (i, r) = (n, w)
    if i < cache.len - 1:
      if i+1 != cache.len - 1:
        result &= ".. "
      else:
        result &= pfx
      result &= cache[^1][0].ppNtry
    result[^1] = '}'
  else:
    result &= "}"

proc ppBe[T](be: T; db: AristoDb; indent: int): string =
  ## Walk over backend tables
  let
    pfx = indent.toPfx
    pfx1 = indent.toPfx(1)
    pfx2 = indent.toPfx(2)
  result = "<" & $be.kind & ">"
  result &= pfx & "vGen" & pfx1 & "[" & be.walkIdg.toSeq.mapIt(
      it[2].mapIt(it.ppVid).join(",")
    ).join(",") & "]"
  result &= pfx & "sTab" & pfx1 & "{" & be.walkVtx.toSeq.mapIt(
      $(1+it[0]) & "(" & it[1].ppVid & "," & it[2].ppVtx(db,it[1]) & ")"
    ).join(pfx2) & "}"
  result &= pfx & "kMap" & pfx1 & "{" & be.walkKey.toSeq.mapIt(
      $(1+it[0]) & "(" & it[1].ppVid & "," & it[2].ppKey & ")"
    ).join(pfx2) & "}"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc lblToVtxID*(db: var AristoDb, lbl: HashLabel): VertexID =
  ## Associate a vertex ID with the argument `key` for pretty printing.
  if lbl.isValid:
    let vid = db.xMap.getOrVoid lbl
    if vid.isValid:
      result = vid
    else:
      result = db.vidFetch()
      db.xMap[lbl] = result

proc hashToVtxID*(db: var AristoDb, root: VertexID; hash: Hash256): VertexID =
  db.lblToVtxID HashLabel(root: root, key: hash.to(HashKey))

proc pp*(key: HashKey): string =
  key.ppKey

proc pp*(lbl: HashLabel, db = AristoDb()): string =
  lbl.ppLabel(db)

proc pp*(lty: LeafTie, db = AristoDb()): string =
  lty.ppLeafTie(db)

proc pp*(vid: VertexID): string =
  vid.ppVid

proc pp*(vGen: openArray[VertexID]): string =
  "[" & vGen.mapIt(it.ppVid).join(",") & "]"

proc pp*(p: PayloadRef, db = AristoDb()): string =
  p.ppPayload(db)

proc pp*(nd: VertexRef, db = AristoDb()): string =
  nd.ppVtx(db, VertexID(0))

proc pp*(nd: NodeRef; root: VertexID; db: var AristoDB): string =
  if not nd.isValid:
    result = "n/a"
  elif nd.error != AristoError(0):
    result = "(!" & $nd.error
  else:
    result = ["L(", "X(", "B("][nd.vType.ord]
    case nd.vType:
    of Leaf:
      result &= $nd.lPfx.ppPathPfx & "," & nd.lData.pp(db)

    of Extension:
      let lbl = HashLabel(root: root, key: nd.key[0])
      result &= $nd.ePfx.ppPathPfx & "," & nd.eVid.ppVid & ","
      result &= lbl.ppLabel(db) & db.labelVidUpdate(lbl, nd.eVid)

    of Branch:
      result &= "["
      for n in 0..15:
        if nd.bVid[n].isValid or nd.key[n].isValid:
          result &= nd.bVid[n].ppVid
        let lbl = HashLabel(root: root, key: nd.key[n])
        result &= db.labelVidUpdate(lbl, nd.bVid[n]) & ","
      result[^1] = ']'

      result &= ",["
      for n in 0..15:
        if nd.bVid[n].isValid or nd.key[n].isValid:
          result &= HashLabel(root: root, key: nd.key[n]).ppLabel(db)
        result &= ","
      result[^1] = ']'
  result &= ")"

proc pp*(nd: NodeRef): string =
  var db = AristoDB()
  nd.pp(db)

proc pp*(sTab: Table[VertexID,VertexRef]; db = AristoDb(); indent = 4): string =
  "{" & sTab.sortedKeys
            .mapIt((it, sTab.getOrVoid it))
            .filterIt(it[1].isValid)
            .mapIt("(" & it[0].ppVid & "," & it[1].ppVtx(db,it[0]) & ")")
            .join("," & indent.toPfx(1)) & "}"

proc pp*(lTab: Table[LeafTie,VertexID]; indent = 4): string =
  var db = AristoDb()
  "{" & lTab.sortedKeys
            .mapIt((it, lTab.getOrVoid it))
            .filterIt(it[1].isValid)
            .mapIt("(" & it[0].ppLeafTie(db) & "," & it[1].ppVid & ")")
            .join("," & indent.toPfx(1)) & "}"

proc pp*(pPrf: HashSet[VertexID]): string =
  "{" & pPrf.sortedKeys.mapIt(it.ppVid).join(",") & "}"

proc pp*(leg: Leg; db = AristoDb()): string =
  result = "(" & leg.wp.vid.ppVid & ","
  if not db.top.isNil:
    let lbl = db.top.kMap.getOrVoid leg.wp.vid
    if not lbl.isValid:
      result &= "ø"
    elif leg.wp.vid != db.top.pAmk.getOrVoid lbl:
      result &= lbl.ppLabel(db)
  result &= ","
  if leg.backend:
    result &= "*"
  result &= ","
  if 0 <= leg.nibble:
    result &= $leg.nibble.ppNibble
  result &= "," & leg.wp.vtx.pp(db) & ")"

proc pp*(hike: Hike; db = AristoDb(); indent = 4): string =
  let pfx = indent.toPfx(1)
  result = "["
  if hike.legs.len == 0:
    result &= "(" & hike.root.ppVid & ")"
  else:
    if hike.legs[0].wp.vid != hike.root:
      result &= "(" & hike.root.ppVid & ")" & pfx
    result &= hike.legs.mapIt(it.pp(db)).join(pfx)
  result &= pfx & "(" & hike.tail.ppPathPfx & ")"
  if hike.error != AristoError(0):
    result &= pfx & "(" & $hike.error & ")"
  result &= "]"

proc pp*(kMap: Table[VertexID,Hashlabel]; indent = 4): string =
  var db: AristoDb
  "{" & kMap.sortedKeys
            .mapIt((it,kMap.getOrVoid it))
            .filterIt(it[1].isValid)
            .mapIt("(" & it[0].ppVid & "," & it[1].ppLabel(db) & ")")
            .join("," & indent.toPfx(1)) & "}"

proc pp*(pAmk: Table[Hashlabel,VertexID]; indent = 4): string =
  var
    db: AristoDb
    rev = pAmk.pairs.toSeq.mapIt((it[1],it[0])).toTable
  "{" & rev.sortedKeys
           .mapIt((it,rev.getOrVoid it))
           .filterIt(it[1].isValid)
           .mapIt("(" & it[1].ppLabel(db) & "," & it[0].ppVid & ")")
           .join("," & indent.toPfx(1)) & "}"

proc pp*(kMap: Table[VertexID,Hashlabel]; db: AristoDb; indent = 4): string =
  db.ppXMap(kMap, db.top.pAmk, indent)

proc pp*(pAmk: Table[Hashlabel,VertexID]; db: AristoDb; indent = 4): string =
  db.ppXMap(db.top.kMap, pAmk, indent)

proc pp*(
    be: MemBackendRef|RdbBackendRef;
    db: AristoDb;
    indent = 4;
      ): string =
  be.ppBe(db, indent)

# ---------------------

proc pp*(
    db: AristoDb;
    vGenOk = true;
    sTabOk = true;
    lTabOk = true;
    kMapOk = true;
    pPrfOk = true;
    indent = 4;
      ): string =
  let
    pfx1 = indent.toPfx
    pfx2 = indent.toPfx(1)
    tagOk = 1 < sTabOk.ord + lTabOk.ord + kMapOk.ord + pPrfOk.ord + vGenOk.ord
  var
    pfy = ""

  proc doPrefix(s: string): string =
    var rc: string
    if tagOk:
      rc = pfy & s & pfx2
      pfy = pfx1
    else:
      rc = pfy
      pfy = pfx2
    rc

  if not db.top.isNil:
    if vGenOk:
      let info = "vGen(" & $db.top.vGen.len & ")"
      result &= info.doPrefix & db.top.vGen.pp
    if sTabOk:
      let info = "sTab(" & $db.top.sTab.len & ")"
      result &= info.doPrefix & db.top.sTab.pp(db,indent+1)
    if lTabOk:
      let info = "lTab(" & $db.top.lTab.len & ")"
      result &= info.doPrefix & db.top.lTab.pp(indent+1)
    if kMapOk:
      let info = "kMap(" & $db.top.kMap.len & "," & $db.top.pAmk.len & ")"
      result &= info.doPrefix & db.ppXMap(db.top.kMap,db.top.pAmk,indent+1)
    if pPrfOk:
      let info = "pPrf(" & $db.top.pPrf.len & ")"
      result &= info.doPrefix & db.top.pPrf.pp

proc pp*(
  be: AristoTypedBackendRef;
  db: AristoDb;
  indent = 4;
    ): string =

  case (if be.isNil: BackendNone else: be.kind)
  of BackendMemory:
    be.MemBackendRef.ppBe(db, indent)

  of BackendRocksDB:
    be.RdbBackendRef.ppBe(db, indent)

  of BackendNone:
    "n/a"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
