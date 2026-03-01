# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## In-memory backend for Kvt DB
## ============================
##
## The iterators provided here are currently available only by direct
## backend access
## ::
##   import
##     kvt/kvt_init/kvt_memory
##
##   let rc = newKvtDbRef(BackendMemory)
##   if rc.isOk:
##     let be = rc.value.to(MemBackendRef)
##     for (n, key, vtx) in be.walkVtx:
##       ...
##
{.push raises: [].}

import
  std/[tables, sets],
  chronicles,
  results,
  stew/byteutils,
  ./init_common,
  ../kvt_desc

type
  MemBackendRef* = ref object of TypedBackendRef
    tab: Table[seq[byte],seq[byte]]  ## Structural key-value table

  MemPutHdlRef = ref object of TypedPutHdlRef
    tab: Table[seq[byte],seq[byte]]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "MemoryDB " & info


proc newSession(db: MemBackendRef): MemPutHdlRef =
  new result
  result.TypedPutHdlRef.beginSession db

proc getSession(hdl: PutHdlRef; db: MemBackendRef): MemPutHdlRef =
  hdl.TypedPutHdlRef.verifySession db
  hdl.MemPutHdlRef

proc endSession(hdl: PutHdlRef; db: MemBackendRef): MemPutHdlRef =
  hdl.TypedPutHdlRef.finishSession db
  hdl.MemPutHdlRef

# ------------------------------------------------------------------------------
# Private functions: interface
# ------------------------------------------------------------------------------

proc getKvpFn(db: MemBackendRef): GetKvpFn =
  result =
    proc(key: openArray[byte]): Result[seq[byte],KvtError] =
      if key.len == 0:
        return err(KeyInvalid)
      var data = db.tab.getOrVoid @key
      if data.isValid:
        return ok(move(data))
      err(GetNotFound)

proc lenKvpFn(db: MemBackendRef): LenKvpFn =
  result =
    proc(key: openArray[byte]): Result[int,KvtError] =
      if key.len == 0:
        return err(KeyInvalid)
      var data = db.tab.getOrVoid @key
      if data.isValid:
        return ok(data.len)
      err(GetNotFound)

proc multiGetKvpFn(db: MemBackendRef): MultiGetKvpFn =
  result =
    proc(keys: openArray[seq[byte]], values: var openArray[Opt[seq[byte]]],
         sortedInput: bool): Result[void, KvtError] =
      assert keys.len() > 0
      assert keys.len() == values.len()

      for i, k in keys:
        if k.len() == 0:
          return err(KeyInvalid)

        var data = db.tab.getOrVoid(@k)
        if data.isValid:
          values[i] = Opt.some(move(data))
        else:
          values[i] = Opt.none(seq[byte])

      ok()

# -------------

proc putBegFn(db: MemBackendRef): PutBegFn =
  result =
    proc(): Result[PutHdlRef,KvtError] =
      ok db.newSession()

proc putKvpFn(db: MemBackendRef): PutKvpFn =
  result =
    proc(hdl: PutHdlRef; k, v: openArray[byte]) =
      let hdl = hdl.getSession db
      if hdl.error == KvtError(0):
        if k.len > 0:
          hdl.tab[@k] = @v
        else:
          hdl.tab.del @k

proc putEndFn(db: MemBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,KvtError] =
      let hdl = hdl.endSession db
      if hdl.error != KvtError(0):
        debug logTxt "putEndFn: key/value failed", error=hdl.error
        return err(hdl.error)

      for k, v in hdl.tab:
        db.tab[k] = v

      ok()

# -------------

proc delKvpFn(db: MemBackendRef): DelKvpFn =
  result =
    proc(key: openArray[byte]): Result[void, KvtError] =
      if key.len == 0:
        return err(KeyInvalid)

      db.tab.del(@key)

      ok()

proc delRangeKvpFn(db: MemBackendRef): DelRangeKvpFn =
  result =
    proc(startKey, endKey: openArray[byte], compactRange: bool): Result[void, KvtError] =
      if startKey.len == 0 or endKey.len == 0:
        return err(KeyInvalid)

      var toDelete: HashSet[seq[byte]]
      for k in db.tab.keys():
        if (k == startKey or k > startKey) and k < endKey:
          toDelete.incl(k)

      for k in toDelete:
        db.tab.del(k)

      ok()

# -------------

proc closeFn(db: MemBackendRef): CloseFn =
  result =
    proc(ignore: bool) =
      discard


# -------------

proc getBackendFn(db: MemBackendRef): GetBackendFn =
  result =
    proc(): TypedBackendRef =
      db

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc memoryBackend*: KvtDbRef =
  let
    be = MemBackendRef(beKind: BackendMemory)
    db = KvtDbRef()

  db.getKvpFn = getKvpFn be
  db.lenKvpFn = lenKvpFn be
  db.multiGetKvpFn = multiGetKvpFn be

  db.putBegFn = putBegFn be
  db.putKvpFn = putKvpFn be
  db.putEndFn = putEndFn be

  db.delKvpFn = delKvpFn(be)
  db.delRangeKvpFn = delRangeKvpFn(be)

  db.closeFn = closeFn be
  db.getBackendFn = getBackendFn be
  db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walk*(
    be: MemBackendRef;
      ): tuple[key: seq[byte], data: seq[byte]] =
  ## Walk over all key-value pairs of the database.
  for key, data in be.tab:
    if data.isValid:
      yield (key, data)
    else:
      debug logTxt "walk() skip empty", key

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
