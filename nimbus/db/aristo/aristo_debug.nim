# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
  results,
  stew/byteutils,
  "."/[aristo_constants, aristo_desc, aristo_get, aristo_hike],
  ./aristo_desc/desc_backend,
  ./aristo_init/[memory_db, memory_only, rocks_db],
  ./aristo_filter/filter_scheduler

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc toHex(w: VertexID): string =
  w.uint64.toHex

proc toHexLsb(w: int8): string =
  $"0123456789abcdef"[w and 15]

proc sortedKeys(lTab: Table[LeafTie,VertexID]): seq[LeafTie] =
  lTab.keys.toSeq.sorted(cmp = proc(a,b: LeafTie): int = cmp(a,b))

proc sortedKeys(kMap: Table[VertexID,HashLabel]): seq[VertexID] =
  kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID)

proc sortedKeys(kMap: Table[VertexID,HashKey]): seq[VertexID] =
  kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID)

proc sortedKeys(sTab: Table[VertexID,VertexRef]): seq[VertexID] =
  sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID)

proc sortedKeys(pPrf: HashSet[VertexID]): seq[VertexID] =
  pPrf.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID)

proc toPfx(indent: int; offset = 0): string =
  if 0 < indent+offset: "\n" & " ".repeat(indent+offset) else: ""

proc lidVidUpdate(
    db: AristoDbRef;
    root: VertexID;
    lid: HashKey;
    vid: VertexID;
      ): string =
  if lid.isValid and vid.isValid:
    let lbl = HashLabel(root: root, key: lid)
    if not db.top.isNil:
      let vids = db.top.pAmk.getOrVoid lbl
      if vids.isValid:
        if vid notin vids:
          result = "(!)"
        return
    block:
      let vids = db.xMap.getOrVoid lbl
      if vids.isValid:
        if vid notin vids:
          result = "(!)"
        return
    db.xMap.append(lbl, vid)

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

proc stripZeros(a: string; toExp = false): string =
  if 0 < a.len:
    result = a.strip(leading=true, trailing=false, chars={'0'})
    if result.len == 0:
      result = "0"
    elif result[^1] == '0' and toExp:
      var n = 0
      while result[^1] == '0':
        let w = result.len
        result.setLen(w-1)
        n.inc
      if n == 1:
        result &= "0"
      elif n == 2:
        result &= "00"
      elif 2 < n:
        result &= "↑" & $n

proc vidCode(lbl: HashLabel, db: AristoDbRef): uint64 =
  if lbl.isValid:
    if not db.top.isNil:
      let vids = db.top.pAmk.getOrVoid lbl
      if vids.isValid:
        return vids.sortedKeys[0].uint64
    block:
      let vids = db.xMap.getOrVoid lbl
      if vids.isValid:
        return vids.sortedKeys[0].uint64

# ---------------------

proc ppVid(vid: VertexID; pfx = true): string =
  if pfx:
    result = "$"
  if vid.isValid:
    result &= vid.toHex.stripZeros.toLowerAscii
  else:
    result &= "ø"

func ppCodeHash(h: Hash256): string =
  result = "¢"
  if h == Hash256():
    result &= "©"
  elif h == EMPTY_CODE_HASH:
    result &= "ø"
  else:
    result &= h.data.toHex.squeeze(hex=true,ignLen=true)

proc ppFid(fid: FilterID): string =
  if not fid.isValid:
    return "ø"
  "@" & $fid

proc ppQid(qid: QueueID): string =
  if not qid.isValid:
    return "ø"
  let
    chn = qid.uint64 shr 62
    qid = qid.uint64 and 0x3fff_ffff_ffff_ffffu64
  result = "%"
  if 0 < chn:
    result &= $chn & ":"

  if 0x0fff_ffff_ffff_ffffu64 <= qid.uint64:
    block here:
      if qid.uint64 == 0x0fff_ffff_ffff_ffffu64:
        result &= "(2^60-1)"
      elif qid.uint64 == 0x1fff_ffff_ffff_ffffu64:
        result &= "(2^61-1)"
      elif qid.uint64 == 0x3fff_ffff_ffff_ffffu64:
        result &= "(2^62-1)"
      else:
        break here
      return
  result &= qid.toHex.stripZeros

proc ppVidList(vGen: openArray[VertexID]): string =
  "[" & vGen.mapIt(it.ppVid).join(",") & "]"

#proc ppVidList(vGen: HashSet[VertexID]): string =
#  "{" & vGen.sortedKeys.mapIt(it.ppVid).join(",") & "}"

proc ppKey(key: HashKey; db: AristoDbRef; root: VertexID; pfx = true): string =
  proc getVids: HashSet[VertexID] =
    if not db.top.isNil:
      let vids = db.top.pAmk.getOrVoid HashLabel(root: root, key: key)
      if vids.isValid:
        return vids
    block:
      let vids = db.xMap.getOrVoid HashLabel(root: root, key: key)
      if vids.isValid:
        return vids
  if pfx:
    result = "£"
  if key.len == 0 or key.to(Hash256) == Hash256():
    result &= "©"
  elif not key.isValid:
    result &= "ø"
  else:
    let
      tag = if key.len < 32: "[#" & $key.len & "]" else: ""
      vids = getVids()
    if vids.isValid:
      if not pfx and 0 < tag.len:
        result &= "$"
      if 1 < vids.len: result &= "{"
      result &= vids.sortedKeys.mapIt(it.ppVid(pfx=false)).join(",")
      if 1 < vids.len: result &= "}"
      result &= tag
      return
    result &= @key.toHex.squeeze(hex=true,ignLen=true) & tag

proc ppLabel(lbl: HashLabel; db: AristoDbRef): string =
  if lbl.isValid:
    "%" & ($lbl.root.toHex).stripZeros &
      ":" & lbl.key.ppKey(db, lbl.root, pfx=false)
  else:
    "%ø"

proc ppLeafTie(lty: LeafTie, db: AristoDbRef): string =
  let pfx = lty.path.to(NibblesSeq)
  "@" & lty.root.ppVid(pfx=false) & ":" &
    ($pfx).squeeze(hex=true,ignLen=(pfx.len==64))

proc ppPathPfx(pfx: NibblesSeq): string =
  let s = $pfx
  if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. ^1] & ":" & $s.len

proc ppNibble(n: int8): string =
  if n < 0: "ø" elif n < 10: $n else: n.toHexLsb

proc ppPayload(p: PayloadRef, db: AristoDbRef): string =
  if p.isNil:
    result = "n/a"
  else:
    case p.pType:
    of RawData:
      result &= p.rawBlob.toHex.squeeze(hex=true)
    of RlpData:
      result &= "[#" & p.rlpBlob.toHex.squeeze(hex=true) & "]"
    of AccountData:
      result = "("
      result &= ($p.account.nonce).stripZeros(toExp=true) & ","
      result &= ($p.account.balance).stripZeros(toExp=true) & ","
      result &= p.account.storageID.ppVid & ","
      result &= p.account.codeHash.ppCodeHash & ")"

proc ppVtx(nd: VertexRef, db: AristoDbRef, vid: VertexID): string =
  if not nd.isValid:
    result = "ø"
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

proc ppSTab(
    sTab: Table[VertexID,VertexRef];
    db = AristoDbRef();
    indent = 4;
      ): string =
  "{" & sTab.sortedKeys
            .mapIt((it, sTab.getOrVoid it))
            .mapIt("(" & it[0].ppVid & "," & it[1].ppVtx(db,it[0]) & ")")
            .join(indent.toPfx(1)) & "}"

proc ppLTab(
    lTab: Table[LeafTie,VertexID];
    indent = 4;
      ): string =
  let db = AristoDbRef()
  "{" & lTab.sortedKeys
            .mapIt((it, lTab.getOrVoid it))
            .mapIt("(" & it[0].ppLeafTie(db) & "," & it[1].ppVid & ")")
            .join(indent.toPfx(1)) & "}"

proc ppPPrf(pPrf: HashSet[VertexID]): string =
  "{" & pPrf.sortedKeys.mapIt(it.ppVid).join(",") & "}"

proc ppXMap*(
    db: AristoDbRef;
    kMap: Table[VertexID,HashLabel];
    pAmk: Table[HashLabel,HashSet[VertexID]];
    indent: int;
      ): string =

  let pfx = indent.toPfx(1)

  var dups: HashSet[VertexID]
  for vids in pAmk.values:
    if 1 < vids.len:
      dups = dups + vids

  # Vertex IDs without forward mapping `kMap: VertexID -> HashLabel`
  var revOnly: Table[VertexID,HashLabel]
  for (lbl,vids) in pAmk.pairs:
    for vid in vids:
      if not kMap.hasKey vid:
        revOnly[vid] = lbl
  let revKeys =
    revOnly.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID)

  proc ppNtry(n: uint64): string =
    var s = VertexID(n).ppVid
    let lbl = kMap.getOrVoid VertexID(n)
    if lbl.isValid:
      let vids = pAmk.getOrVoid lbl
      if VertexID(n) notin vids or 1 < vids.len:
        s = "(" & s & "," & lbl.key.ppKey(db,lbl.root)
      elif lbl.key.len < 32:
        s &= "[#" & $lbl.key.len & "]"
    else:
      s &= "£ø"
    if s[0] == '(':
      s &= ")"
    s & ","

  result = "{"
  # Extra reverse lookups
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
          if i+1 == n-1:
            result &= pfx
          else:
            result &= ".. "
          result &= revKeys[n-1].ppRevlabel
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
      cache.add (vid.uint64, lbl.vidCode(db), vid in dups)
      let vids = pAmk.getOrVoid lbl
      if (0 < vids.len and vid notin vids) or lbl.key.len < 32:
        cache[^1][2] = true
    else:
      cache.add (vid.uint64, 0u64, true)

  if 0 < cache.len:
    var (i, r) = (0, cache[0])
    if 0 < revKeys.len:
      result &= pfx
    result &= cache[i][0].ppNtry
    for n in 1 ..< cache.len:
      let
        m = cache[n-1]
        w = cache[n]
      r = (r[0]+1, r[1]+1, r[2])
      if r != w or w[2]:
        if i+1 != n:
          if i+1 == n-1:
            result &= pfx
          else:
            result &= ".. "
          result &= m[0].ppNtry
        result &= pfx & w[0].ppNtry
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

proc ppFilter(
    fl: FilterRef;
    db: AristoDbRef;
    root: VertexID;
    indent: int;
      ): string =
  ## Walk over filter tables
  let
    pfx = indent.toPfx
    pfx1 = indent.toPfx(1)
    pfx2 = indent.toPfx(2)
  result = "<filter>"
  if fl.isNil:
    result &= " n/a"
    return
  result &= pfx & "fid=" & fl.fid.ppFid
  result &= pfx & "src=" & fl.src.to(HashKey).ppKey(db,root)
  result &= pfx & "trg=" & fl.trg.to(HashKey).ppKey(db,root)
  result &= pfx & "vGen" & pfx1 & "[" &
    fl.vGen.mapIt(it.ppVid).join(",") & "]"
  result &= pfx & "sTab" & pfx1 & "{"
  for n,vid in fl.sTab.sortedKeys:
    let vtx = fl.sTab.getOrVoid vid
    if 0 < n: result &= pfx2
    result &= $(1+n) & "(" & vid.ppVid & "," & vtx.ppVtx(db,vid) & ")"
  result &= "}" & pfx & "kMap" & pfx1 & "{"
  for n,vid in fl.kMap.sortedKeys:
    let key = fl.kMap.getOrVoid vid
    if 0 < n: result &= pfx2
    result &= $(1+n) & "(" & vid.ppVid & "," & key.ppKey(db,root) & ")"
  result &= "}"

proc ppBe[T](be: T; db: AristoDbRef; root: VertexID; indent: int): string =
  ## Walk over backend tables
  let
    pfx = indent.toPfx
    pfx1 = indent.toPfx(1)
    pfx2 = indent.toPfx(2)
  result = "<" & $be.kind & ">"
  result &= pfx & "vGen" & pfx1 & "[" &
    be.getIdgFn().get(otherwise = EmptyVidSeq).mapIt(it.ppVid).join(",") & "]"
  result &= pfx & "sTab" & pfx1 & "{" & be.walkVtx.toSeq.mapIt(
      $(1+it[0]) & "(" & it[1].ppVid & "," & it[2].ppVtx(db,it[1]) & ")"
    ).join(pfx2) & "}"
  result &= pfx & "kMap" & pfx1 & "{" & be.walkKey.toSeq.mapIt(
      $(1+it[0]) & "(" & it[1].ppVid & "," & it[2].ppKey(db,root) & ")"
    ).join(pfx2) & "}"

proc ppLayer(
    layer: LayerRef;
    db: AristoDbRef;
    vGenOk: bool;
    sTabOk: bool;
    lTabOk: bool;
    kMapOk: bool;
    pPrfOk: bool;
    indent = 4;
      ): string =
  let
    pfx1 = indent.toPfx(1)
    pfx2 = indent.toPfx(2)
    nOKs = sTabOk.ord + lTabOk.ord + kMapOk.ord + pPrfOk.ord + vGenOk.ord
    tagOk = 1 < nOKs
  var
    pfy = ""

  proc doPrefix(s: string; dataOk: bool): string =
    var rc: string
    if tagOk:
      rc = pfy & s & (if dataOk: pfx2 else: " ")
      pfy = pfx1
    else:
      rc = pfy
      pfy = pfx2
    rc

  if not layer.isNil:
    if 2 < nOKs:
      result &= "<layer>".doPrefix(false)
    if vGenOk:
      let
        tLen = layer.vGen.len
        info = "vGen(" & $tLen & ")"
      result &= info.doPrefix(0 < tLen) & layer.vGen.ppVidList
    if sTabOk:
      let
        tLen = layer.sTab.len
        info = "sTab(" & $tLen & ")"
      result &= info.doPrefix(0 < tLen) & layer.sTab.ppSTab(db,indent+2)
    if lTabOk:
      let
        tlen = layer.lTab.len
        info = "lTab(" & $tLen & ")"
      result &= info.doPrefix(0 < tLen) & layer.lTab.ppLTab(indent+2)
    if kMapOk:
      let
        tLen = layer.kMap.len
        ulen = layer.pAmk.len
        lInf = if tLen == uLen: $tLen else: $tLen & "," & $ulen
        info = "kMap(" & lInf & ")"
      result &= info.doPrefix(0 < tLen + uLen)
      result &= db.ppXMap(layer.kMap, layer.pAmk, indent+2)
    if pPrfOk:
      let
        tLen = layer.pPrf.len
        info = "pPrf(" & $tLen & ")"
      result &= info.doPrefix(0 < tLen) & layer.pPrf.ppPPrf
    if 0 < nOKs:
      let
        info = if layer.dirty: "dirty" else: "clean"
      result &= info.doPrefix(false)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc pp*(w: Hash256): string =
  if w == EMPTY_ROOT_HASH:
    "EMPTY_ROOT_HASH"
  elif w == Hash256():
    "Hash256()"
  else:
    w.data.toHex.squeeze(hex=true,ignLen=true)

proc pp*(w: HashKey; sig: MerkleSignRef): string =
  w.ppKey(sig.db, sig.root)

proc pp*(w: HashKey; db = AristoDbRef(); root = VertexID(1)): string =
  w.ppKey(db, root)

proc pp*(lbl: HashLabel, db = AristoDbRef()): string =
  lbl.ppLabel(db)

proc pp*(lty: LeafTie, db = AristoDbRef()): string =
  lty.ppLeafTie(db)

proc pp*(vid: VertexID): string =
  vid.ppVid

proc pp*(qid: QueueID): string =
  qid.ppQid

proc pp*(fid: FilterID): string =
  fid.ppFid

proc pp*(a: openArray[(QueueID,QueueID)]): string =
  "[" & a.toSeq.mapIt("(" & it[0].pp & "," & it[1].pp & ")").join(",") & "]"

proc pp*(a: QidAction): string =
  ($a.op).replace("Qid", "") & "(" & a.qid.pp & "," & a.xid.pp & ")"

proc pp*(a: openArray[QidAction]): string =
  "[" & a.toSeq.mapIt(it.pp).join(",") & "]"

proc pp*(vGen: openArray[VertexID]): string =
  vGen.ppVidList

proc pp*(p: PayloadRef, db = AristoDbRef()): string =
  p.ppPayload(db)

proc pp*(nd: VertexRef, db = AristoDbRef()): string =
  nd.ppVtx(db, VertexID(0))

proc pp*(nd: NodeRef; root: VertexID; db: AristoDbRef): string =
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
      result &= $nd.ePfx.ppPathPfx & "," & nd.eVid.ppVid & ","
      result &= nd.key[0].ppKey(db,root)
      result &= db.lidVidUpdate(root, nd.key[0], nd.eVid)

    of Branch:
      result &= "["
      for n in 0..15:
        if nd.bVid[n].isValid or nd.key[n].isValid:
          result &= nd.bVid[n].ppVid
        result &= db.lidVidUpdate(root, nd.key[n], nd.bVid[n]) & ","
      result[^1] = ']'

      result &= ",["
      for n in 0..15:
        if nd.bVid[n].isValid or nd.key[n].isValid:
          result &= nd.key[n].ppKey(db,root)
        result &= ","
      result[^1] = ']'
  result &= ")"

proc pp*(nd: NodeRef): string =
  var db = AristoDbRef()
  nd.pp(db)

proc pp*(
    sTab: Table[VertexID,VertexRef];
    db = AristoDbRef();
    indent = 4;
      ): string =
  sTab.ppSTab

proc pp*(lTab: Table[LeafTie,VertexID]; indent = 4): string =
  lTab.ppLTab

proc pp*(pPrf: HashSet[VertexID]): string =
  pPrf.ppPPrf

proc pp*(leg: Leg; db = AristoDbRef()): string =
  result = "(" & leg.wp.vid.ppVid & ","
  if not db.top.isNil:
    let lbl = db.top.kMap.getOrVoid leg.wp.vid
    if not lbl.isValid:
      result &= "ø"
    elif leg.wp.vid notin db.top.pAmk.getOrVoid lbl:
      result &= lbl.ppLabel(db)
  result &= ","
  if leg.backend:
    result &= "¶"
  result &= ","
  if 0 <= leg.nibble:
    result &= $leg.nibble.ppNibble
  result &= "," & leg.wp.vtx.pp(db) & ")"

proc pp*(hike: Hike; db = AristoDbRef(); indent = 4): string =
  let pfx = indent.toPfx(1)
  result = "["
  if hike.legs.len == 0:
    result &= "(" & hike.root.ppVid & ")"
  else:
    if hike.legs[0].wp.vid != hike.root:
      result &= "(" & hike.root.ppVid & ")" & pfx
    result &= hike.legs.mapIt(it.pp(db)).join(pfx)
  result &= pfx & "(" & hike.tail.ppPathPfx & ")"
  result &= "]"

proc pp*(kMap: Table[VertexID,Hashlabel]; indent = 4): string =
  let db = AristoDbRef()
  "{" & kMap.sortedKeys
            .mapIt((it,kMap.getOrVoid it))
            .filterIt(it[1].isValid)
            .mapIt("(" & it[0].ppVid & "," & it[1].ppLabel(db) & ")")
            .join("," & indent.toPfx(1)) & "}"

proc pp*(pAmk: Table[Hashlabel,VertexID]; indent = 4): string =
  let db = AristoDbRef()
  var rev = pAmk.pairs.toSeq.mapIt((it[1],it[0])).toTable
  "{" & rev.sortedKeys
           .mapIt((it,rev.getOrVoid it))
           .filterIt(it[1].isValid)
           .mapIt("(" & it[1].ppLabel(db) & "," & it[0].ppVid & ")")
           .join("," & indent.toPfx(1)) & "}"

proc pp*(kMap: Table[VertexID,Hashlabel]; db: AristoDbRef; indent = 4): string =
  db.ppXMap(kMap, db.top.pAmk, indent)

proc pp*(pAmk: VidsByLabel; db: AristoDbRef; indent = 4): string =
  db.ppXMap(db.top.kMap, pAmk, indent)

proc pp*(tx: AristoTxRef): string =
  result = "(uid=" & $tx.txUid & ",lvl=" & $tx.level
  if not tx.parent.isNil:
    result &= ", par=" & $tx.parent.txUid
  result &= ")"

proc pp*(wp: VidVtxPair; db: AristoDbRef): string =
  "(" & wp.vid.pp & "," & wp.vtx.pp(db) & ")"

# ---------------------

proc pp*(
    layer: LayerRef;
    db: AristoDbRef;
    indent = 4;
      ): string =
  layer.ppLayer(
    db, vGenOk=true, sTabOk=true, lTabOk=true, kMapOk=true, pPrfOk=true)

proc pp*(
    layer: LayerRef;
    db: AristoDbRef;
    xTabOk: bool;
    indent = 4;
      ): string =
  layer.ppLayer(
    db, vGenOk=true, sTabOk=xTabOk, lTabOk=xTabOk, kMapOk=true, pPrfOk=true)

proc pp*(
    layer: LayerRef;
    db: AristoDbRef;
    xTabOk: bool;
    kMapOk: bool;
    other = false;
    indent = 4;
      ): string =
  layer.ppLayer(
    db, vGenOk=other, sTabOk=xTabOk, lTabOk=xTabOk, kMapOk=kMapOk, pPrfOk=other)


proc pp*(
    db: AristoDbRef;
    xTabOk: bool;
    indent = 4;
      ): string =
  db.top.pp(db, xTabOk=xTabOk, indent=indent)

proc pp*(
    db: AristoDbRef;
    xTabOk: bool;
    kMapOk: bool;
    other = false;
    indent = 4;
      ): string =
  db.top.pp(db, xTabOk=xTabOk, kMapOk=kMapOk, other=other, indent=indent)

proc pp*(
    filter: FilterRef;
    db = AristoDbRef();
    root = VertexID(1);
    indent = 4;
      ): string =
  filter.ppFilter(db, root, indent)

proc pp*(
  be: BackendRef;
  db: AristoDbRef;
  root = VertexID(1);
  indent = 4;
    ): string =
  result = db.roFilter.ppFilter(db, root, indent+1) & indent.toPfx
  case be.kind:
  of BackendMemory:
    result &= be.MemBackendRef.ppBe(db, root, indent)
  of BackendRocksDB:
    result &= be.RdbBackendRef.ppBe(db, root, indent)
  of BackendVoid:
    result &= "<NoBackend>"

proc pp*(
    db: AristoDbRef;
    root = VertexID(1);
    indent = 4;
    backendOk = false;
    filterOk = true;
      ): string =
  result = db.top.pp(db, indent=indent) & indent.toPfx
  if backendOk:
    result &= db.backend.pp(db)
  elif filterOk:
    result &= db.roFilter.ppFilter(db, root, indent+1)

proc pp*(sdb: MerkleSignRef; indent = 4): string =
  "count=" & $sdb.count &
    " root=" & sdb.root.pp &
    " error=" & $sdb.error &
    "\n    db\n    " & sdb.db.pp(root=sdb.root, indent=indent+1)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
