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
  ../../sync/snap/range_desc,
  "."/[aristo_constants, aristo_desc, aristo_error, aristo_hike, aristo_vid]

# ------------------------------------------------------------------------------
# Ptivate functions
# ------------------------------------------------------------------------------

proc toPfx(indent: int): string =
  "\n" & " ".repeat(indent)

proc keyVidUpdate(db: AristoDbRef, key: NodeKey, vid: VertexID): string =
  if not key.isZero and
     not vid.isZero and
     not db.isNil:
    block:
      let keyVid = db.pAmk.getOrDefault(key, VertexID(0))
      if keyVid != VertexID(0):
        if keyVid != vid:
          result = "(!)"
        return
    block:
      let keyVid = db.xMap.getOrDefault(key, VertexID(0))
      if keyVid != VertexID(0):
        if keyVid != vid:
          result = "(!)"
        return
    db.xMap[key] = vid

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
  for n in 0 ..< a.len:
    if a[n] != '0':
      return a[n .. ^1]
  return a

proc ppVid(vid: VertexID): string =
  if vid.isZero: "ø" else: "$" & vid.uint64.toHex.stripZeros.toLowerAscii

proc vidCode(key: NodeKey, db: AristoDbRef): uint64 =
  if not db.isNil and
     not key.isZero and
     key != EMPTY_ROOT_KEY and
     key != EMPTY_CODE_KEY:
    block:
      let vid = db.pAmk.getOrDefault(key, VertexID(0))
      if vid != VertexID(0):
        return vid.uint64
    block:
      let vid = db.xMap.getOrDefault(key, VertexID(0))
      if vid != VertexID(0):
        return vid.uint64

proc ppKey(key: NodeKey, db: AristoDbRef): string =
  if key.isZero:
    return "ø"
  if key == EMPTY_ROOT_KEY:
    return "£r"
  if key == EMPTY_CODE_KEY:
    return "£c"

  if not db.isNil:
    block:
      let vid = db.pAmk.getOrDefault(key, VertexID(0))
      if vid != VertexID(0):
        return "£" & vid.uint64.toHex.stripZeros.toLowerAscii
    block:
      let vid = db.xMap.getOrDefault(key, VertexID(0))
      if vid != VertexID(0):
        return "£" & vid.uint64.toHex.stripZeros.toLowerAscii

  "%" & key.ByteArray32
           .mapIt(it.toHex(2)).join.tolowerAscii
           .squeeze(hex=true,ignLen=true)

proc ppRootKey(a: NodeKey, db: AristoDbRef): string =
  if a != EMPTY_ROOT_KEY:
    return a.ppKey(db)

proc ppCodeKey(a: NodeKey, db: AristoDbRef): string =
  if a != EMPTY_CODE_KEY:
    return a.ppKey(db)

proc ppPathTag(tag: NodeTag, db: AristoDbRef): string =
  ## Raw key, for referenced key dump use `key.pp(db)` below
  if not db.isNil:
    let vid =  db.lTab.getOrDefault(tag, VertexID(0))
    if vid != VertexID(0):
      return "@" & vid.ppVid

  "@" & tag.to(NodeKey).ByteArray32
           .mapIt(it.toHex(2)).join.toLowerAscii
           .squeeze(hex=true,ignLen=true)

proc ppPathPfx(pfx: NibblesSeq): string =
  let s = $pfx
  if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. ^1] & ":" & $s.len

proc ppNibble(n: int8): string =
  if n < 0: "ø" elif n < 10: $n else: n.toHex(1).toLowerAscii

proc ppPayload(p: PayloadRef, db: AristoDbRef): string =
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
      result &= p.account.storageRoot.to(NodeKey).ppRootKey(db) & ","
      result &= p.account.codeHash.to(NodeKey).ppCodeKey(db) & ")"

proc ppVtx(nd: VertexRef, db: AristoDbRef, vid: VertexID): string =
  if nd.isNil:
    result = "n/a"
  else:
    if db.isNil or vid.isZero or vid in db.pPrf:
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
        if not nd.bVid[n].isZero:
          result &= nd.bVid[n].ppVid
        if n < 15:
          result &= ","
    result &= ")"

proc ppXMap*(
    db: AristoDbRef;
    kMap: Table[VertexID,NodeKey];
    pAmk: Table[NodeKey,VertexID];
    indent: int;
      ): string =

  let dups = pAmk.values.toSeq.toCountTable.pairs.toSeq
                 .filterIt(1 < it[1]).toTable

  proc ppNtry(n: uint64): string =
    let
      vid = n.VertexID
      key = kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
    var s = "(" & vid.ppVid & ","
    if key != EMPTY_ROOT_KEY:
      s &= key.ppKey(db)

      let keyVid = pAmk.getOrDefault(key, VertexID(0))
      if keyVid == VertexID(0):
        s &= ",ø"
      elif keyVid != vid:
        s &= "," & keyVid.ppVid

      let count = dups.getOrDefault(vid, 0)
      if 0 < count:
        s &= ",*" & $count
    else:
      s &= "£r(!)"
    s & "),"

  var cache: seq[(uint64,uint64,bool)]
  for vid in toSeq(kMap.keys).mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let key = kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
    if key != EMPTY_ROOT_KEY:
      cache.add (vid.uint64, key.vidCode(db), 0 < dups.getOrDefault(vid, 0))
      let keyVid = pAmk.getOrDefault(key, VertexID(0))
      if keyVid != VertexID(0) and keyVid != vid:
        cache[^1][2] = true
    else:
      cache.add (vid.uint64, 0u64, true)

  result = "{"
  if 0 < cache.len:
    let
      pfx = indent.toPfx
    var
      i = 0
      r = cache[i]
    result &= cache[i][0].ppNtry
    for n in 1 ..< cache.len:
      let w = cache[n]
      r[0].inc
      r[1].inc
      if w != r or w[2]:
        if i+1 != n:
          result &= ".. "
        result &= cache[n-1][0].ppNtry & pfx & " " & cache[n][0].ppNtry
        i = n
        r = w
    if i < cache.len - 1:
      result &= ".. " & cache[^1][0].ppNtry
    result[^1] = '}'
  else:
    result &= "}"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc keyToVtxID*(db: AristoDbRef, key: NodeKey): VertexID =
  ## Associate a vertex ID with the argument `key` for pretty printing.
  if not key.isZero and
     key != EMPTY_ROOT_KEY and
     key != EMPTY_CODE_KEY and
     not db.isNil:
    let vid = db.xMap.getOrDefault(key, VertexID(0))
    if vid != VertexID(0):
      result = vid
    else:
      result = db.vidFetch()
      db.xMap[key] = result

proc pp*(vid: NodeKey, db = AristoDbRef(nil)): string =
  vid.ppKey(db)

proc pp*(tag: NodeTag, db = AristoDbRef(nil)): string =
  tag.ppPathTag(db)

proc pp*(vid: VertexID): string =
  vid.ppVid

proc pp*(vid: openArray[VertexID]): string =
  "[" & vid.mapIt(it.ppVid).join(",") & "]"

proc pp*(p: PayloadRef, db = AristoDbRef(nil)): string =
  p.ppPayload(db)

proc pp*(nd: VertexRef, db = AristoDbRef(nil)): string =
  nd.ppVtx(db, VertexID(0))

proc pp*(nd: NodeRef, db = AristoDbRef(nil)): string =
  if nd.isNil:
    result = "n/a"
  elif nd.isError:
    result = "(!" & $nd.error
  else:
    result = ["L(", "X(", "B("][nd.vType.ord]
    case nd.vType:
    of Leaf:
      result &= $nd.lPfx.ppPathPfx & "," & nd.lData.pp(db)

    of Extension:
      result &= $nd.ePfx.ppPathPfx & "," & nd.eVid.ppVid & ","
      result &= nd.key[0].ppKey(db)
      result &= db.keyVidUpdate(nd.key[0], nd.eVid)

    of Branch:
      result &= "["
      for n in 0..15:
        if not nd.bVid[n].isZero or not nd.key[n].isZero:
          result &= nd.bVid[n].ppVid
        result &= db.keyVidUpdate(nd.key[n], nd.bVid[n]) & ","
      result[^1] = ']'

      result &= ",["
      for n in 0..15:
        if not nd.bVid[n].isZero or not nd.key[n].isZero:
          result &= nd.key[n].ppKey(db)
        result &= ","
      result[^1] = ']'
  result &= ")"

proc pp*(
    sTab: Table[VertexID,VertexRef];
    db = AristoDbRef(nil);
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  var first = true
  result = "{"
  for vid in toSeq(sTab.keys).mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let vtx = sTab.getOrDefault(vid, VertexRef(nil))
    if vtx != VertexRef(nil):
      if first:
        first = false
      else:
        result &= pfx & " "
      result &= "(" & vid.ppVid & "," & vtx.ppVtx(db,vid) & ")"
  result &= "}"

proc pp*(
    lTab: Table[NodeTag,VertexID];
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  var first = true
  result = "{"
  for tag in toSeq(lTab.keys).mapIt(it.UInt256).sorted.mapIt(it.NodeTag):
    let vid = lTab.getOrDefault(tag, VertexID(0))
    if vid != VertexID(0):
      if first:
        first = false
      else:
        result &= pfx & " "
      result &= "(" & tag.ppPathTag(nil) & "," & vid.ppVid & ")"
  result &= "}"

proc pp*(vGen: seq[VertexID]): string =
  result = "["
  for vid in vGen:
    result &= vid.ppVid & ","
  if result[^1] == ',':
    result[^1] = ']'
  else:
    result &= "]"

proc pp*(pPrf: HashSet[VertexID]): string =
  result = "{"
  for vid in pPrf.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    result &= vid.ppVid & ","
  if result[^1] == ',':
    result[^1] = '}'
  else:
    result &= "}"

proc pp*(
    leg: Leg;
    db = AristoDbRef(nil);
      ): string =
  result = " (" & leg.wp.vid.ppVid & ","
  if not db.isNil:
    let key = db.kMap.getOrDefault(leg.wp.vid, EMPTY_ROOT_KEY)
    if key != EMPTY_ROOT_KEY:
      result &= key.ppKey(db)
    else:
      result &= "ø"
  result &= "," & $leg.nibble.ppNibble & "," & leg.wp.vtx.pp(db) & ")"

proc pp*(
    hike: Hike;
    db = AristoDbRef(nil);
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  var first = true
  result = "[(" & hike.root.ppVid & ")"
  for leg in hike.legs:
    result &= "," & pfx & leg.pp(db)
  result &= "," & pfx & " (" & hike.tail.ppPathPfx & ")"
  if hike.error != AristoError(0):
    result &= "," & pfx & " (" & $hike.error & ")"
  result &= "]"

proc pp*(
    kMap: Table[VertexID,NodeKey];
    db = AristoDbRef(nil);
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  var first = true
  result = "{"
  for vid in toSeq(kMap.keys).mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let key = kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
    if key != EMPTY_ROOT_KEY:
      if first:
        first = false
      else:
        result &= pfx & " "
      result &= "(" & vid.ppVid & "," & key.ppKey(db) & "),"
  if result[^1] == ',':
    result[^1] = '}'
  else:
    result &= "}"

proc pp*(
    pAmk: Table[NodeKey,VertexID];
    db = AristoDbRef(nil);
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  var
    rev = pAmk.pairs.toSeq.mapIt((it[1],it[0])).toTable
    first = true
  result = "{"
  for vid in rev.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let key = rev.getOrDefault(vid, EMPTY_ROOT_KEY)
    if key != EMPTY_ROOT_KEY:
      if first:
        first = false
      else:
        result &= pfx & " "
      result &= "(" & key.ppKey(db) & "," & vid.ppVid & "),"
  if result[^1] == ',':
    result[^1] = '}'
  else:
    result &= "}"

# ---------------------

proc pp*(
    db: AristoDbRef;
    sTabOk = true;
    lTabOk = true;
    kMapOk = true;
    pPrfOk = true;
    indent = 4;
      ): string =
  let
    pfx1 = max(indent-1,0).toPfx
    pfx2 = indent.toPfx
    labelOk = 1 < sTabOk.ord + lTabOk.ord + kMapOk.ord + pPrfOk.ord
  var
    pfy1 = ""
    pfy2 = ""

  proc doPrefix(s: string): string =
    var rc: string
    if labelOk:
      rc = pfy1 & s & pfx2
      pfy1 = pfx1
    else:
      rc = pfy2
      pfy2 = pfx2
    rc

  if sTabOk:
    let info = "sTab(" & $db.sTab.len & ")"
    result &= info.doPrefix & db.sTab.pp(db,indent)
  if lTabOk:
    let info = "lTab(" & $db.lTab.len & "),root=" & db.lRoot.ppVid
    result &= info.doPrefix & db.lTab.pp(indent)
  if kMapOk:
    let info = "kMap(" & $db.kMap.len & "," & $db.pAmk.len & ")"
    result &= info.doPrefix & db.ppXMap(db.kMap,db.pAmk,indent)
  if pPrfOk:
    let info = "pPrf(" & $db.pPrf.len & ")"
    result &= info.doPrefix & db.pPrf.pp

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
