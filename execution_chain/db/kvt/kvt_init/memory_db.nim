# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
##     kvt/kvt_init,
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
  std/tables,
  chronicles,
  results,
  stew/byteutils,
  ../kvt_desc,
  ../kvt_desc/desc_backend,
  ./init_common

type
  MemDbRef = ref object
    ## Database
    tab: Table[seq[byte],seq[byte]]  ## Structural key-value table

  MemBackendRef* = ref object of TypedBackendRef
    ## Inheriting table so access can be extended for debugging purposes
    mdb: MemDbRef                    ## Database

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
      var data = db.mdb.tab.getOrVoid @key
      if data.isValid:
        return ok(move(data))
      err(GetNotFound)

proc lenKvpFn(db: MemBackendRef): LenKvpFn =
  result =
    proc(key: openArray[byte]): Result[int,KvtError] =
      if key.len == 0:
        return err(KeyInvalid)
      var data = db.mdb.tab.getOrVoid @key
      if data.isValid:
        return ok(data.len)
      err(GetNotFound)

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

      for (k,v) in hdl.tab.pairs:
        db.mdb.tab[k] = v

      ok()

# -------------

proc closeFn(db: MemBackendRef): CloseFn =
  result =
    proc(ignore: bool) =
      discard

proc setWrReqFn(db: MemBackendRef): SetWrReqFn =
  result =
    proc(kvt: RootRef): Result[void,KvtError] =
      err(RdbBeHostNotApplicable)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc memoryBackend*: BackendRef =
  let db = MemBackendRef(
    beKind: BackendMemory,
    mdb:    MemDbRef())

  db.getKvpFn = getKvpFn db
  db.lenKvpFn = lenKvpFn db

  db.putBegFn = putBegFn db
  db.putKvpFn = putKvpFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db
  db.setWrReqFn = setWrReqFn db
  db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walk*(
    be: MemBackendRef;
      ): tuple[key: seq[byte], data: seq[byte]] =
  ## Walk over all key-value pairs of the database.
  for (key,data) in be.mdb.tab.pairs:
    if data.isValid:
      yield (key, data)
    else:
      debug logTxt "walk() skip empty", key

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
