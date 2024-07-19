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
  std/[algorithm, sequtils, strutils, tables],
  eth/common,
  results,
  stew/byteutils,
  ./kvt_desc/desc_backend,
  ./kvt_init/[memory_db, memory_only, rocks_db],
  "."/[kvt_desc, kvt_layers]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc squeeze(s: string, hex = false, ignLen = false): string =
  ## For long strings print `begin..end` only
  if hex:
    let n = (s.len + 1) div 2
    result =
      if s.len < 20:
        s
      else:
        s[0 .. 5] & ".." & s[s.len - 8 .. ^1]
    if not ignLen:
      result &= "[" & (if 0 < n: "#" & $n else: "") & "]"
  elif s.len <= 30:
    result = s
  else:
    result =
      if (s.len and 1) == 0:
        s[0 ..< 8]
      else:
        "0" & s[0 ..< 7]
    if not ignLen:
      result &= "..(" & $s.len & ")"
    result &= ".." & s[s.len - 16 .. ^1]

#proc stripZeros(a: string): string =
#  a.strip(leading=true, trailing=false, chars={'0'})

proc toPfx(indent: int, offset = 0): string =
  if 0 < indent + offset:
    "\n" & " ".repeat(indent + offset)
  else:
    ""

func getOrVoid*(tab: Table[Blob, uint64], w: Blob): uint64 =
  tab.getOrDefault(w, 0u64)

func getOrVoid*(tab: Table[uint64, Blob], w: uint64): Blob =
  tab.getOrDefault(w, EmptyBlob)

func isValid*(id: uint64): bool =
  0 < id

proc keyID(key: Blob, db = KvtDbRef(nil)): uint64 =
  if key.len == 0:
    return 0
  elif db.isNil:
    return high(uint64)
  else:
    let
      ctr = db.getCentre
      id = ctr.xMap.getOrVoid key
    if id.isValid:
      id
    else:
      # Save new ID
      ctr.xIdGen.inc
      ctr.xMap[key] = db.xIdGen
      ctr.pAmx[db.xIdGen] = key
      ctr.xIdGen

#proc keyBlob(id: uint64; db = KvtDbRef(nil)): Blob =
#  if 0 < id and not db.isNil:
#    result = db.getCentre.pAmx.getOrVoid id

proc ppID(id: uint64): string =
  "$" & (if id == 0: "ø" else: $id)

proc ppKey(key: Blob, db = KvtDbRef(nil)): string =
  if key.len == 0:
    0.ppID
  elif db.isNil:
    key[0 .. 0].toHex & "-" &
      key[1 ..< key.len].toHex.squeeze(hex = true, ignLen = (key.len == 33))
  else:
    key.keyID(db).ppID

proc ppValue(data: Blob): string =
  data.toHex.squeeze(hex = true)

proc ppTab(tab: Table[Blob, Blob], db = KvtDbRef(nil), indent = 4): string =
  result = "{"
  if db.isNil:
    let keys = tab.keys.toSeq.sorted
    result &=
      keys
      .mapIt((it, tab.getOrVoid it))
      .mapIt("(" & it[0].ppKey & "," & it[1].ppValue & ")")
      .join(indent.toPfx(1))
  else:
    let keys = tab.keys.toSeq.mapIt(it.keyID db).sorted
    result &=
      keys
      .mapIt((it, tab.getOrVoid db.pAmx.getOrVoid(it)))
      .mapIt("(" & it[0].ppID & "," & it[1].ppValue & ")")
      .join(indent.toPfx(1))
  result &= "}"

proc ppMap(tab: Table[uint64, Blob], indent = 4): string =
  let keys = tab.keys.toSeq.sorted
  "{" &
    keys
    .mapIt((it, tab.getOrVoid it))
    .mapIt("(" & it[0].ppID & "," & it[1].ppKey & ")")
    .join(indent.toPfx(1)) & "}"

proc ppBe[T](be: T, db: KvtDbRef, indent: int): string =
  ## Walk over backend table
  let
    pfx1 = indent.toPfx(1)
    pfx2 = indent.toPfx(2)
    pfx3 = indent.toPfx(3)
  var
    data = ""
    n = 0
  for (key, val) in be.walk:
    if 0 < n:
      data &= pfx3
    n.inc
    data &= $n & "(" & key.ppKey(db) & "," & val.ppValue & ")"
  var spc = if 0 < n: pfx2 else: " "
  "<" & $be.kind & ">" & pfx1 & "tab" & spc & "{" & data & "}"

proc ppLayer(layer: LayerRef, db: KvtDbRef, indent = 4): string =
  let
    tLen = layer.sTab.len
    info = "tab(" & $tLen & ")"
    pfx1 = indent.toPfx(1)
    pfx2 =
      if 0 < tLen:
        indent.toPfx(2)
      else:
        " "
  "<layer>" & pfx1 & info & pfx2 & layer.sTab.ppTab(db, indent + 2)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc pp*(be: BackendRef, db: KvtDbRef, indent = 4): string =
  case be.kind
  of BackendMemory:
    result &= be.MemBackendRef.ppBe(db, indent)
  of BackendRocksDB, BackendRdbTriggered:
    result &= be.RdbBackendRef.ppBe(db, indent)
  of BackendVoid:
    result &= "<NoBackend>"

proc pp*(db: KvtDbRef, backendOk = false, keysOk = false, indent = 4): string =
  let
    pfx = indent.toPfx
    pfx1 = indent.toPfx(1)
  result = db.layersCc.ppLayer(db, indent = indent)
  if backendOk:
    result &= pfx & db.backend.pp(db, indent = indent)
  if keysOk:
    result &= pfx & "<keys>" & pfx1 & db.getCentre.pAmx.ppMap(indent = indent + 1)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
