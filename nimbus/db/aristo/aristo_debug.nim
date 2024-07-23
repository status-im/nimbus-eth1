# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  eth/common,
  results,
  stew/[byteutils, interval_set],
  ./aristo_desc/desc_backend,
  ./aristo_init/[memory_db, memory_only, rocks_db],
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_layers,
       aristo_serialise, aristo_utils]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc orDefault(db: AristoDbRef): AristoDbRef =
  if db.isNil: AristoDbRef(top: LayerRef.init()) else: db

proc add(
    xMap: var Table[HashKey,HashSet[RootedVertexID]];
    key: HashKey;
    vid: RootedVertexID;
      ) =
  xMap.withValue(key,value):
    value[].incl vid
  do: # else if not found
    xMap[key] = @[vid].toHashSet

# --------------------------

proc toHex(w: VertexID): string =
  w.uint64.toHex

proc toHexLsb(w: int8): string =
  $"0123456789abcdef"[w and 15]

proc sortedKeys(tab: Table): seq =
  tab.keys.toSeq.sorted

proc sortedKeys(pPrf: HashSet): seq =
  pPrf.toSeq.sorted

proc toPfx(indent: int; offset = 0): string =
  if 0 < indent+offset: "\n" & " ".repeat(indent+offset) else: ""

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

# ---------------------

proc ppKeyOk(
    db: AristoDbRef;
    key: HashKey;
    rvid: RootedVertexID;
      ): string =
  if key.isValid and rvid.isValid:
    block:
      let vids = db.xMap.getOrVoid key
      if vids.isValid:
        if rvid notin vids:
          result = "(!)"
        return
    db.xMap.add(key,rvid)

proc ppVid(vid: VertexID; pfx = true): string =
  if pfx:
    result = "$"
  if vid.isValid:
    result &= vid.toHex.stripZeros.toLowerAscii
  else:
    result &= "ø"

proc ppVid(rvid: RootedVertexID; pfx = true): string =
  if pfx:
    result = "$"
  result &= ppVid(rvid.root, pfx=false) & ":" & ppVid(rvid.vid, pfx=false)

proc ppVids(vids: HashSet[RootedVertexID]): string =
  result = "{"
  if vids.len == 0:
    result &= "}"
  else:
    for vid in vids.toSeq.sorted:
      result &= ppVid(vid)
      result &= ","
    result[^1] = '}'

func ppCodeHash(h: Hash256): string =
  result = "¢"
  if h == Hash256():
    result &= "©"
  elif h == EMPTY_CODE_HASH:
    result &= "ø"
  else:
    result &= h.data.toHex.squeeze(hex=true,ignLen=true)

proc ppVidList(vLst: openArray[VertexID]): string =
  result = "["
  if vLst.len <= 250:
    result &= vLst.mapIt(it.ppVid).join(",")
  else:
    result &= vLst[0 .. 99].mapIt(it.ppVid).join(",")
    result &= ",.."
    result &= vLst[^100 .. ^1].mapIt(it.ppVid).join(",")
  result &= "]"

proc ppKey(key: HashKey; db: AristoDbRef; pfx = true): string =
  if pfx:
    result = "£"
  if key.to(Hash256) == Hash256():
    result &= "©"
  elif not key.isValid:
    result &= "ø"
  else:
    # Reverse lookup
    var rvid = (VertexID(0),VertexID(0))
    for rv in db.xMap.getOrVoid key:
      let vtx = db.getVtx rv
      if vtx.isValid:
        let rc = vtx.toNode(rv.root, db)
        if rc.isOk and key == rc.value.digestTo(HashKey):
          rvid = rv
          break
    # Ok, assemble key representation
    let tag = if key.len < 32: "[#" & $key.len & "]" else: ""
    if rvid.isValid:
      result &= rvid.ppVid(pfx=false)
    else:
      db.xMap.del key
      result &= @(key.data).toHex.squeeze(hex=true,ignLen=true) & tag

proc ppLeafTie(lty: LeafTie, db: AristoDbRef): string =
  let pfx = lty.path.to(NibblesBuf)
  "@" & lty.root.ppVid(pfx=false) & ":" &
    ($pfx).squeeze(hex=true,ignLen=(pfx.len==64))

proc ppPathPfx(pfx: NibblesBuf): string =
  let s = $pfx
  if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. ^1] & ":" & $s.len

proc ppNibble(n: int8): string =
  if n < 0: "ø" elif n < 10: $n else: n.toHexLsb

proc ppPayload(p: LeafPayload, db: AristoDbRef): string =
  case p.pType:
  of RawData:
    result &= p.rawBlob.toHex.squeeze(hex=true)
  of AccountData:
    result = "("
    result &= ($p.account.nonce).stripZeros(toExp=true) & ","
    result &= ($p.account.balance).stripZeros(toExp=true) & ","
    result &= p.stoID.ppVid & ","
    result &= p.account.codeHash.ppCodeHash & ")"
  of StoData:
    result = $p.stoData

proc ppVtx(nd: VertexRef, db: AristoDbRef, rvid: RootedVertexID): string =
  if not nd.isValid:
    result = "ø"
  else:
    if not rvid.isValid:
      result = ["L(", "B("][nd.vType.ord]
    elif db.layersGetKey(rvid).isOk:
      result = ["l(", "b("][nd.vType.ord]
    else:
      result = ["ł(", "þ("][nd.vType.ord]
    case nd.vType:
    of Leaf:
      result &= nd.lPfx.ppPathPfx & "," & nd.lData.ppPayload(db)
    of Branch:
      result &= nd.ePfx.ppPathPfx & ":"
      for n in 0..15:
        if nd.bVid[n].isValid:
          result &= nd.bVid[n].ppVid
        if n < 15:
          result &= ","
    result &= ")"

proc ppSTab(
    sTab: Table[RootedVertexID,VertexRef];
    db: AristoDbRef;
    indent = 4;
      ): string =
  "{" & sTab.sortedKeys
            .mapIt((it, sTab.getOrVoid it))
            .mapIt("(" & it[0].ppVid & "," & it[1].ppVtx(db,it[0]) & ")")
            .join(indent.toPfx(1)) & "}"

proc ppXMap*(
    db: AristoDbRef;
    kMap: Table[RootedVertexID,HashKey];
    indent: int;
      ): string =
  let pfx = indent.toPfx(1)

  # Sort keys by root,
  #   entry int: 0=no-key 1=no-vertex 2=cant-compile 3=key-mistmatch 4=key-ok
  var keyLst: seq[(VertexID,seq[(VertexID,HashKey,int)])]
  block:
    var root = VertexID(0)
    for w in kMap.sortedKeys:
      if w.root != root:
        keyLst.add (w.root,newSeq[typeof keyLst[0][1][0]](0))
        root = w.root
      let
        key = kMap.getOrVoid w
        mode = block:
          if key == VOID_HASH_KEY:
            0
          else:
            db.xMap.add(key,w)
            let vtx = db.getVtx(w)
            if not vtx.isValid:
              1
            else:
              let rc = vtx.toNode(w.root, db)
              if rc.isErr:
                2
              elif key != rc.value.digestTo(HashKey):
                3
              else:
                4
      keyLst[^1][1].add (w.vid,key,mode)

  proc pp(w: (VertexID,HashKey,int)): string =
    proc pp(k: HashKey): string =
      result = w[1].data.toHex.squeeze(hex=true,ignLen=true)
      if k.len < 32:
        result &= "[#" & $k.len & "]"
    w[0].ppVid(pfx=false) & (
      case w[2]:
      of 0: "=ø"
      of 1: "(!)"
      of 2: "=" & w[1].pp()
      of 3: "≠" & w[1].pp()
      else: "")

  var qfx = ""
  for (vid,q) in keyLst:
    result &= qfx & "{£" & vid.ppVid(pfx=false) & ":"
    qfx = pfx
    if 1 < q.len:
      result &= "["
    for w in q:
      # TODO: optimise consecutive ranges
      result &= w.pp & ","
    if 1 < q.len:
      result[^1] = ']'
    else:
      result.setLen(result.len - 1)
  result &= "}"

proc ppBalancer(
    fl: LayerRef;
    db: AristoDbRef;
    indent: int;
      ): string =
  ## Walk over filter tables
  let
    pfx = indent.toPfx
    pfx1 = indent.toPfx(1)
    pfx2 = indent.toPfx(2)
  result = "<balancer>"
  if fl.isNil:
    result &= " n/a"
    return
  result &= pfx & "vTop=" & fl.vTop.ppVid
  result &= pfx & "sTab" & pfx1 & "{"
  for n,vid in fl.sTab.sortedKeys:
    let vtx = fl.sTab.getOrVoid vid
    if 0 < n: result &= pfx2
    result &= $(1+n) & "(" & vid.ppVid & "," & vtx.ppVtx(db,vid) & ")"
  result &= "}" & pfx & "kMap" & pfx1 & "{"
  for n,vid in fl.kMap.sortedKeys:
    let key = fl.kMap.getOrVoid vid
    if 0 < n: result &= pfx2
    result &= $(1+n) & "(" & vid.ppVid & "," & key.ppKey(db) & ")"
  result &= "}"

proc ppBe[T](be: T; db: AristoDbRef; limit: int; indent: int): string =
  ## Walk over backend tables
  let
    pfx = indent.toPfx
    pfx1 = indent.toPfx(1)
    pfx2 = indent.toPfx(2)
  result = "<" & $be.kind & ">"
  var (dump,dataOk) = ("",false)
  block:
    let rc = be.getTuvFn()
    if rc.isOk:
      dump &= pfx & "vTop=" & rc.value.ppVid
      dataOk = true
  block:
    dump &= pfx & "sTab"
    var (n, data) = (0, "")
    for (vid,vtx) in be.walkVtx:
      n.inc
      if n < limit:
        if 1 < n: data &= pfx2
        data &= $n & "(" & vid.ppVid & "," & vtx.ppVtx(db,vid) & ")"
      elif n == limit:
        data &= pfx2 & ".."
    dump &= "(" & $n & ")"
    if 0 < n:
      dataOk = true
      dump &= pfx1
    dump &= "{" & data & "}"
  block:
    dump &= pfx & "kMap"
    var (n, data) = (0, "")
    for (vid,key) in be.walkKey:
      n.inc
      if n < limit:
        if 1 < n: data &= pfx2
        data &= $n & "(" & vid.ppVid & "," & key.ppKey(db) & ")"
      elif n == limit:
        data &= pfx2 & ".."
    dump &= "(" & $n & ")"
    if 0 < n:
      dataOk = true
      dump &= pfx1
    dump &= "{" & data & "}"
  if dataOk:
    result &= dump
  else:
    result &= "[]"

proc ppLayer(
    layer: LayerRef;
    db: AristoDbRef;
    vTopOk: bool;
    sTabOk: bool;
    kMapOk: bool;
    indent = 4;
      ): string =
  let
    pfx1 = indent.toPfx(1)
    pfx2 = indent.toPfx(2)
    nOKs = vTopOk.ord + sTabOk.ord + kMapOk.ord
    tagOk = 1 < nOKs
  var
    pfy = ""

  proc doPrefix(s: string; dataOk: bool): string =
    var rc: string
    if tagOk:
      rc = pfy
      if 0 < s.len:
        rc &= s & (if dataOk: pfx2 else: "")
      pfy = pfx1
    else:
      rc = pfy
      pfy = pfx2
    rc

  if not layer.isNil:
    if 2 < nOKs:
      result &= "<layer>".doPrefix(false)
    if vTopOk:
      result &= "".doPrefix(true) & "vTop=" & layer.vTop.ppVid
    if sTabOk:
      let
        tLen = layer.sTab.len
        info = "sTab(" & $tLen & ")"
      result &= info.doPrefix(0 < tLen) & layer.sTab.ppSTab(db,indent+2)
    if kMapOk:
      let
        tLen = layer.kMap.len
        info = "kMap(" & $tLen & ")"
      result &= info.doPrefix(0 < tLen)
      result &= db.ppXMap(layer.kMap, indent+2)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc pp*(w: Hash256; codeHashOk = false): string =
  if codeHashOk:
    w.ppCodeHash
  elif w == EMPTY_ROOT_HASH:
    "EMPTY_ROOT_HASH"
  elif w == Hash256():
    "Hash256()"
  else:
    w.data.toHex.squeeze(hex=true,ignLen=true)

proc pp*(w: HashKey; sig: MerkleSignRef): string =
  w.ppKey(sig.db)

proc pp*(w: Hash256; sig: MerkleSignRef): string =
  w.to(HashKey).ppKey(sig.db)

proc pp*(w: HashKey; db = AristoDbRef(nil)): string =
  w.ppKey(db.orDefault)

proc pp*(w: Hash256; db = AristoDbRef(nil)): string =
  w.to(HashKey).ppKey(db.orDefault)

proc pp*(w: openArray[HashKey]; db = AristoDbRef(nil)): string =
  "[" & @w.mapIt(it.ppKey(db.orDefault)).join(",") & "]"

proc pp*(lty: LeafTie, db = AristoDbRef(nil)): string =
  lty.ppLeafTie(db.orDefault)

proc pp*(vid: VertexID): string =
  vid.ppVid

proc pp*(rvid: RootedVertexID): string =
  rvid.ppVid

proc pp*(vLst: openArray[VertexID]): string =
  vLst.ppVidList

proc pp*(p: LeafPayload, db = AristoDbRef(nil)): string =
  p.ppPayload(db.orDefault)

proc pp*(nd: VertexRef, db = AristoDbRef(nil)): string =
  nd.ppVtx(db.orDefault, default(RootedVertexID))

proc pp*[T](rc: Result[T,(VertexID,AristoError)]): string =
  if rc.isOk:
    result = "ok("
    when T isnot void:
      result &= ".."
    result &= ")"
  else:
    result = "err((" & rc.error[0].pp & "," & $rc.error[1] & "))"

proc pp*(
    sTab: Table[RootedVertexID,VertexRef];
    db = AristoDbRef(nil);
    indent = 4;
      ): string =
  sTab.ppSTab(db.orDefault)

proc pp*(root: VertexID, leg: Leg; db = AristoDbRef(nil)): string =
  let db = db.orDefault()
  result = "(" & leg.wp.vid.ppVid & ","
  block:
    let key = db.layersGetKeyOrVoid (root, leg.wp.vid)
    if not key.isValid:
      result &= "ø"
    elif (root, leg.wp.vid) notin db.xMap.getOrVoid key:
      result &= key.ppKey(db)
  result &= ","
  if 0 <= leg.nibble:
    result &= $leg.nibble.ppNibble
  result &= "," & leg.wp.vtx.pp(db) & ")"

proc pp*(hike: Hike; db = AristoDbRef(nil); indent = 4): string =
  let
    db = db.orDefault()
    pfx = indent.toPfx(1)
  result = "["
  if hike.legs.len == 0:
    result &= "(" & hike.root.ppVid & ")"
  else:
    if hike.legs[0].wp.vid != hike.root:
      result &= "(" & hike.root.ppVid & ")" & pfx
    result &= hike.legs.mapIt(pp(hike.root, it, db)).join(pfx)
  result &= pfx & "(" & hike.tail.ppPathPfx & ")"
  result &= "]"

proc pp*(kMap: Table[VertexID,HashKey]; indent = 4): string =
  let db =  AristoDbRef(nil).orDefault
  "{" & kMap.sortedKeys
            .mapIt((it, kMap.getOrVoid it))
            .mapIt("(" & it[0].ppVid & "," & it[1].ppKey(db) & ")")
            .join("," & indent.toPfx(1)) & "}"

proc pp*(kMap: Table[RootedVertexID,HashKey]; db: AristoDbRef; indent = 4): string =
  db.ppXMap(kMap, indent)

# ---------------------

proc pp*(tx: AristoTxRef): string =
  result = "(uid=" & $tx.txUid & ",level=" & $tx.level
  if not tx.parent.isNil:
    result &= ", par=" & $tx.parent.txUid
  result &= ")"

proc pp*(wp: VidVtxPair; db: AristoDbRef): string =
  "(" & wp.vid.pp & "," & wp.vtx.pp(db) & ")"


proc pp*(
    layer: LayerRef;
    db: AristoDbRef;
    indent = 4;
    balancerOk = false;
    sTabOk = true,
    kMapOk = true,
    other = true,
      ): string =
  if balancerOk:
    layer.ppLayer(
      db.orDefault(), vTopOk=other, sTabOk=sTabOk, kMapOk=kMapOk)
  else:
    layer.ppLayer(
      db.orDefault(), vTopOk=other, sTabOk=sTabOk, kMapOk=kMapOk)

proc pp*(
  be: BackendRef;
  db: AristoDbRef;
  limit = 100;
  indent = 4;
    ): string =
  result = db.balancer.ppBalancer(db, indent+1) & indent.toPfx
  case be.kind:
  of BackendMemory:
    result &= be.MemBackendRef.ppBe(db, limit, indent+1)
  of BackendRocksDB, BackendRdbHosting:
    result &= be.RdbBackendRef.ppBe(db, limit, indent+1)
  of BackendVoid:
    result &= "<NoBackend>"

proc pp*(
    db: AristoDbRef;
    indent = 4;
    backendOk = false;
    balancerOk = true;
    topOk = true;
    stackOk = true;
    kMapOk = true;
    sTabOk = true;
    limit = 100;
      ): string =
  if topOk:
    result = db.layersCc.pp(
      db, sTabOk=sTabOk, kMapOk=kMapOk, other=true, indent=indent)
  let stackOnlyOk = stackOk and not (topOk or balancerOk or backendOk)
  if not stackOnlyOk:
    result &= indent.toPfx & "level=" & $db.stack.len
  if (stackOk and 0 < db.stack.len) or stackOnlyOk:
    let layers = @[db.top] & db.stack.reversed
    var lStr = ""
    for n,w in layers:
      let
        m = layers.len - n - 1
        l = db.layersCc m
        a = w.kMap.values.toSeq.filterIt(not it.isValid).len
        c = l.kMap.values.toSeq.filterIt(not it.isValid).len
      result &= "(" & $(w.kMap.len - a) & "," & $a & ")"
      lStr &= " " & $m & "=(" & $(l.kMap.len - c) & "," & $c & ")"
    result &= " =>" & lStr
  if backendOk:
    result &= indent.toPfx & db.backend.pp(db, limit=limit, indent)
  elif balancerOk:
    result &= indent.toPfx & db.balancer.ppBalancer(db, indent+1)

proc pp*(sdb: MerkleSignRef; indent = 4): string =
  result = "" &
    "count=" & $sdb.count &
    " root=" & sdb.root.pp
  if sdb.error != AristoError(0):
    result &= " error=" & $sdb.error
  result &= "\n    db\n    " & sdb.db.pp(indent=indent+1)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
