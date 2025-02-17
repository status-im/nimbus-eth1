# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  "."/[aristo_desc, aristo_get, aristo_layers,
       aristo_serialise, aristo_utils]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func orDefault(db: AristoTxRef): AristoTxRef =
  if db.isNil: AristoTxRef() else: db

# --------------------------

func toHex(w: VertexID): string =
  w.uint64.toHex

func toHexLsb(w: int8): string =
  $"0123456789abcdef"[w and 15]

func sortedKeys(tab: Table): seq =
  tab.keys.toSeq.sorted

func sortedKeys(pPrf: HashSet): seq =
  pPrf.toSeq.sorted

func toPfx(indent: int; offset = 0): string =
  if 0 < indent+offset: "\n" & " ".repeat(indent+offset) else: ""

func squeeze(s: string; hex = false; ignLen = false): string =
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

func stripZeros(a: string; toExp = false): string =
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

func ppKeyOk(
    db: AristoTxRef;
    key: HashKey;
    rvid: RootedVertexID;
      ): string =
  if key.isValid and rvid.isValid:
    let rv = db.db.xMap.getOrVoid key
    if rv.isValid:
      if rvid != rv:
        result = "(!)"
      return
    db.db.xMap[key] = rvid

func ppVid(vid: VertexID; pfx = true): string =
  if pfx:
    result = "$"
  if vid.isValid:
    result &= vid.toHex.stripZeros.toLowerAscii
  else:
    result &= "ø"

func ppVid(sid: StorageID; pfx = true): string =
  if sid.isValid or not sid.vid.isValid:
    sid.vid.ppVid(pfx)
  else:
    (if pfx: "$" else: "") & "®" & sid.vid.ppVid(false)

func ppVid(rvid: RootedVertexID; pfx = true): string =
  if pfx:
    result = "$"
  result &= ppVid(rvid.root, pfx=false) & ":" & ppVid(rvid.vid, pfx=false)

func ppCodeHash(h: Hash32): string =
  result = "¢"
  if h == default(Hash32):
    result &= "©"
  elif h == EMPTY_CODE_HASH:
    result &= "ø"
  else:
    result &= h.data.toHex.squeeze(hex=true,ignLen=true)

func ppVidList(vLst: openArray[VertexID]): string =
  result = "["
  if vLst.len <= 250:
    result &= vLst.mapIt(it.ppVid).join(",")
  else:
    result &= vLst[0 .. 99].mapIt(it.ppVid).join(",")
    result &= ",.."
    result &= vLst[^100 .. ^1].mapIt(it.ppVid).join(",")
  result &= "]"

proc ppKey(key: HashKey; db: AristoTxRef; pfx = true): string =
  if pfx:
    result = "£"
  if key.to(Hash32) == default(Hash32):
    result &= "©"
  elif not key.isValid:
    result &= "ø"
  else:
    # Reverse lookup
    let rvid = db.db.xMap.getOrVoid key
    if rvid.isValid:
      result &= rvid.ppVid(pfx=false)
      let vtx = db.getVtx rvid
      if vtx.isValid:
        let rc = vtx.toNode(rvid.root, db)
        if rc.isErr or key != rc.value.digestTo(HashKey):
          result &= "≠"
      else:
        result &= "∞"
    else:
      let tag = if key.len < 32: "[#" & $key.len & "]" else: ""
      result &= @(key.data).toHex.squeeze(hex=true,ignLen=true) & tag

func ppLeafTie(lty: LeafTie, db: AristoTxRef): string =
  let pfx = lty.path.to(NibblesBuf)
  "@" & lty.root.ppVid(pfx=false) & ":" &
    ($pfx).squeeze(hex=true,ignLen=(pfx.len==64))

func ppPathPfx(pfx: NibblesBuf): string =
  let s = $pfx
  if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. ^1] & ":" & $s.len

func ppNibble(n: int8): string =
  if n < 0: "ø" elif n < 10: $n else: n.toHexLsb

proc ppEthAccount(a: Account, db: AristoTxRef): string =
  result = "("
  result &= ($a.nonce).stripZeros(toExp=true) & ","
  result &= ($a.balance).stripZeros(toExp=true) & ","
  result &= a.codeHash.ppCodeHash & ","
  result &= a.storageRoot.to(HashKey).ppKey(db) & ")"

func ppAriAccount(a: AristoAccount): string =
  result = "("
  result &= ($a.nonce).stripZeros(toExp=true) & ","
  result &= ($a.balance).stripZeros(toExp=true) & ","
  result &= a.codeHash.ppCodeHash & ")"

func ppPayload(p: LeafPayload, db: AristoTxRef): string =
  case p.pType:
  of AccountData:
    result = "(" & p.account.ppAriAccount() & "," & p.stoID.ppVid & ")"
  of StoData:
    result = ($p.stoData).squeeze

func ppVtx(nd: VertexRef, db: AristoTxRef, rvid: RootedVertexID): string =
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
      result &= nd.pfx.ppPathPfx & "," & nd.lData.ppPayload(db)
    of Branch:
      result &= nd.pfx.ppPathPfx & ":"
      for n in 0'u8..15'u8:
        if nd.bVid(n).isValid:
          result &= nd.bVid(n).ppVid
        if n < 15:
          result &= ","
    result &= ")"


proc ppNode(
    nd: NodeRef;
    db: AristoTxRef;
    rvid = default(RootedVertexID);
      ): string =
  if not nd.isValid:
    result = "ø"
  else:
    if not rvid.isValid:
      result = ["L(", "B("][nd.vtx.vType.ord]
    elif db.layersGetKey(rvid).isOk:
      result = ["l(", "b("][nd.vtx.vType.ord]
    else:
      result = ["ł(", "þ("][nd.vtx.vType.ord]
    case nd.vtx.vType:
    of Leaf:
      result &= nd.vtx.pfx.ppPathPfx & ","
      if nd.vtx.lData.pType == AccountData:
        result &= "(" & nd.vtx.lData.account.ppAriAccount() & ","
        if nd.vtx.lData.stoID.isValid:
          let tag = db.ppKeyOk(nd.key[0],(rvid.root,nd.vtx.lData.stoID.vid))
          result &= nd.vtx.lData.stoID.ppVid & tag
        else:
          result &= nd.vtx.lData.stoID.ppVid
          if nd.key[0].isValid:
            result &= nd.key[0].ppKey(db)
        result &= ")"
      else:
        result &= nd.vtx.lData.ppPayload(db)
    of Branch:
      let keyOnly = nd.vtx.subVids.toSeq.filterIt(it.isValid).len == 0
      result &= nd.vtx.pfx.ppPathPfx & ":"
      for n in 0'u8..15'u8:
        if nd.vtx.bVid(n).isValid:
          let tag = db.ppKeyOk(nd.key[n],(rvid.root,nd.vtx.bVid(n)))
          result &= nd.vtx.bVid(n).ppVid & tag
        elif keyOnly and nd.key[n].isValid:
          result &= nd.key[n].ppKey(db)
        if n < 15:
          result &= ","
    result &= ")"


func ppXTab[T: VertexRef|NodeRef](
    tab: Table[RootedVertexID,T];
    db: AristoTxRef;
    indent = 4;
      ): string =
  proc ppT(v: T; r: RootedVertexID): string =
    when T is VertexRef:
      v.ppVtx(db, r)
    elif T is NodeRef:
      v.ppNode(db, r)
  "{" & tab.sortedKeys
           .mapIt((it, tab.getOrDefault it))
           .mapIt("(" & it[0].ppVid & "," & it[1].ppT(it[0]) & ")")
           .join(indent.toPfx(1)) & "}"


proc ppXMap*(
    db: AristoTxRef;
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
            db.db.xMap[key] = w
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

  # Join increasing sequences for pretty printing
  var keySubLst: seq[(VertexID,seq[seq[(VertexID,HashKey,int)]])]
  for (root,rootQ) in keyLst:
    var
      q: seq[(VertexID,HashKey,int)]
      subQ: seq[typeof q]
    for (vid,key,state) in rootQ:
      if q.len == 0:
        q.add (vid,key,state)
        continue
      if q[^1][0]+1 == vid and q[^1][2] == state:
        q.add (vid,key,state)
        continue
      # Otherwise new sub queue
      subQ.add q
      q = @[(vid,key,state)]
    if 0 < q.len:
      subQ.add q
    keySubLst.add (root,subQ)

  proc pp(w: (VertexID,HashKey,int)): string =
    proc pp(k: HashKey): string =
      result = w[1].data.toHex.squeeze(hex=true,ignLen=true)
      if k.len < 32:
        result &= "[#" & $k.len & "]"
    w[0].ppVid(pfx=false) & (
      case w[2]:
      of 0: "=ø"
      of 1: "∞"
      of 2: "=" & w[1].pp()
      of 3: "≠" & w[1].pp()
      else: "")

  result &= "{"

  var qfx = ""
  for (root,subQ) in keySubLst:
    result &= qfx & "£" & root.ppVid(pfx=false) & ":"
    qfx = pfx
    var closeBracket = ""
    if 1 < subQ.len or 1 < subQ[0].len:
      result &= "["
      closeBracket = "]"
    for q in subQ:
      if q.len < 3:
        result &= q.mapIt(it.pp).join(",")
      else:
        result &= q[0].pp & ".." & q[^1].pp
      result &= ","
    result.setLen(result.len - 1)
    result &= closeBracket

  result &= "}"


proc ppBalancer(
    fl: AristoTxRef;
    db: AristoTxRef;
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

proc ppBe[T](be: T; db: AristoTxRef; limit: int; indent: int): string =
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
    layer: AristoTxRef;
    db: AristoTxRef;
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
      result &= info.doPrefix(0 < tLen) & layer.sTab.ppXTab(db,indent+2)
    if kMapOk:
      let
        tLen = layer.kMap.len
        info = "kMap(" & $tLen & ")"
      result &= info.doPrefix(0 < tLen)
      result &= db.ppXMap(layer.kMap, indent+2)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func pp*(w: Hash32; codeHashOk: bool): string =
  if codeHashOk:
    w.ppCodeHash
  elif w == EMPTY_ROOT_HASH:
    "EMPTY_ROOT_HASH"
  elif w == default(Hash32):
    "default(Hash32)"
  else:
    w.data.toHex.squeeze(hex=true,ignLen=true)

func pp*(n: NibblesBuf): string =
  n.ppPathPfx()

proc pp*(w: HashKey; db = AristoTxRef(nil)): string =
  w.ppKey(db.orDefault)

proc pp*(w: Hash32; db = AristoTxRef(nil)): string =
  w.to(HashKey).ppKey(db.orDefault)

proc pp*(w: openArray[HashKey]; db = AristoTxRef(nil)): string =
  "[" & @w.mapIt(it.ppKey(db.orDefault)).join(",") & "]"

func pp*(lty: LeafTie, db = AristoTxRef(nil)): string =
  lty.ppLeafTie(db.orDefault)

proc pp*(a: Account, db = AristoTxRef(nil)): string =
  a.ppEthAccount(db.orDefault)

func pp*(vid: VertexID): string =
  vid.ppVid

func pp*(rvid: RootedVertexID): string =
  rvid.ppVid

func pp*(vLst: openArray[VertexID]): string =
  vLst.ppVidList

func pp*(p: LeafPayload, db = AristoTxRef(nil)): string =
  p.ppPayload(db.orDefault)

func pp*(nd: VertexRef, db = AristoTxRef(nil)): string =
  nd.ppVtx(db.orDefault, default(RootedVertexID))

proc pp*(nd: NodeRef, db = AristoTxRef(nil)): string =
  nd.ppNode(db.orDefault, default(RootedVertexID))

func pp*(e: (VertexID,AristoError)): string =
  "(" & e[0].pp & "," & $e[1] & ")"

func pp*[T](rc: Result[T,(VertexID,AristoError)]): string =
  if rc.isOk:
    result = "ok("
    when T isnot void:
      result &= ".."
    result &= ")"
  else:
    result = "err(" & rc.error.pp & ")"

func pp*(
    sTab: Table[RootedVertexID,VertexRef];
    db = AristoTxRef(nil);
    indent = 4;
      ): string =
  sTab.ppXTab(db.orDefault)

proc pp*(leg: Leg; root: VertexID; db = AristoTxRef(nil)): string =
  let db = db.orDefault()
  result = "(" & leg.wp.vid.ppVid & ","
  block:
    let key = db.layersGetKeyOrVoid (root, leg.wp.vid)
    if not key.isValid:
      result &= "ø"
    elif (root, leg.wp.vid) != db.db.xMap.getOrVoid key:
      result &= key.ppKey(db)
  result &= ","
  if 0 <= leg.nibble:
    result &= $leg.nibble.ppNibble
  result &= "," & leg.wp.vtx.pp(db) & ")"

proc pp*(hike: Hike; db = AristoTxRef(nil); indent = 4): string =
  let
    db = db.orDefault()
    pfx = indent.toPfx(1)
  result = "["
  if hike.legs.len == 0:
    result &= "(" & hike.root.ppVid & ")"
  else:
    if hike.legs[0].wp.vid != hike.root:
      result &= "(" & hike.root.ppVid & ")" & pfx
    result &= hike.legs.mapIt(it.pp(hike.root, db)).join(pfx)
  result &= pfx & "(" & hike.tail.ppPathPfx & ")"
  result &= "]"

func pp*[T: NodeRef|VertexRef|HashKey](
    q: seq[(HashKey,T)];
    db = AristoTxRef(nil);
    indent = 4;
      ): string =
  let db = db.orDefault
  proc ppT(v: T): string =
    when T is VertexID or T is RootedVertexID:
      v.pp()
    else:
      v.pp(db)
  "{" & q.mapIt("(" & it[0].ppKey(db) & "," & it[1].ppT & ")")
         .join("," & indent.toPfx(1)) & "}"

func pp*[T: NodeRef|VertexRef|HashKey](
    t: Table[HashKey,T];
    db = AristoTxRef(nil);
    indent = 4;
      ): string =
  ## Sort hash keys by associated vertex ID were possible
  let db = db.orDefault
  var
    t0: Table[RootedVertexID,(HashKey,T)]
    t1: Table[HashKey,T]
  for (key,val) in t.pairs:
    db.xMap.withValue(key,rv):
      t0[rv[]] = (key,val)
    do:
      t1[key] = val
  let
    q0 = t0.sortedKeys.mapIt(t0.getOrDefault it)
    q1 = t1.sortedKeys.mapIt((it, t1.getOrDefault it))
  (q0 & q1).pp(db,indent)

proc pp*[T: HashKey](
    t: Table[T,RootedVertexID];
    db = AristoTxRef(nil);
    indent = 4;
      ): string =
  ## Sort by second tab item vertex ID
  let db = db.orDefault
  proc ppT(v: T): string =
    when T is VertexID or T is RootedVertexID:
      v.pp()
    else:
      v.pp(db)
  var rev: Table[RootedVertexID,seq[T]]
  for (key,rvid) in t.pairs:
    rev.withValue(rvid,val):
      val[].add key
    do:
      rev[rvid] = @[key]
  var flat: seq[(HashKey,RootedVertexID)]
  for rvid in rev.keys.toSeq.sorted:
    rev.withValue(rvid,keysPtr):
      for key in keysPtr[]:
        flat.add (key,rvid)
  # Now sorted vy values
  "{" & flat.mapIt("(" & it[0].ppT & "," & it[1].pp & ")")
            .join("," & indent.toPfx(1)) & "}"

func pp*[T: HashKey](
    t: TableRef[HashKey,T];
    db = AristoTxRef(nil);
    indent = 4;
      ): string =
  pp(t[],db,indent)

proc pp*(
    kMap: Table[RootedVertexID,HashKey];
    db: AristoTxRef;
    indent = 4;
      ): string =
  db.ppXMap(kMap, indent)

# ---------------------

func pp*(tx: AristoTxRef): string =
  result = "(" & repr(pointer(addr(tx[])))
  if not tx.parent.isNil:
    result &= ", par=" & pp(tx.parent)
  result &= ")"

func pp*(wp: VidVtxPair; db: AristoTxRef): string =
  "(" & wp.vid.pp & "," & wp.vtx.pp(db) & ")"


proc pp*(
    layer: AristoTxRef;
    db: AristoTxRef;
    indent = 4;
    sTabOk = true,
    kMapOk = true,
    vTopOk = true,
      ): string =
  layer.ppLayer(
    db.orDefault(), vTopOk=vTopOk, sTabOk=sTabOk, kMapOk=kMapOk, indent=indent)

proc pp*(
  be: BackendRef;
  db: AristoTxRef;
  limit = 100;
  indent = 4;
    ): string =
  result = db.ppBalancer(db, indent+1) & indent.toPfx
  case be.kind:
  of BackendMemory:
    result &= be.MemBackendRef.ppBe(db, limit, indent+1)
  of BackendRocksDB:
    result &= be.RdbBackendRef.ppBe(db, limit, indent+1)

proc pp*(
    db: AristoTxRef;
    indent = 4;
    backendOk = false;
    balancerOk = true;
    topOk = true;
    stackOk = true;
    kMapOk = true;
    sTabOk = true;
    limit = 100;
      ): string =
  # if topOk:
  #   result = db.layersCc.ppLayer(
  #     db, sTabOk=sTabOk, kMapOk=kMapOk, vTopOk=true, indent=indent)
  # let stackOnlyOk = stackOk and not (topOk or balancerOk or backendOk)
  # if not stackOnlyOk:
  #   result &= indent.toPfx(1) & "level=" & $db.stack.len
  # if (stackOk and 0 < db.stack.len) or stackOnlyOk:
  #   let layers = @[db.top] & db.stack.reversed
  #   var lStr = ""
  #   for n,w in layers:
  #     let
  #       m = layers.len - n - 1
  #       l = db.layersCc m
  #       a = w.kMap.values.toSeq.filterIt(not it.isValid).len
  #       c = l.kMap.values.toSeq.filterIt(not it.isValid).len
  #     result &= "(" & $(w.kMap.len - a) & "," & $a & ")"
  #     lStr &= " " & $m & "=(" & $(l.kMap.len - c) & "," & $c & ")"
  #   result &= " =>" & lStr
  # if backendOk:
  #   result &= indent.toPfx & db.backend.pp(db, limit=limit, indent)
  # elif balancerOk:
  #   result &= indent.toPfx & db.balancer.ppBalancer(db, indent+1)
  discard #TODO
# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
