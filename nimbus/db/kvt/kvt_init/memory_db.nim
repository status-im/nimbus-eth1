# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
  eth/common,
  results,
  stew/byteutils,
  ../kvt_desc,
  ../kvt_desc/desc_backend,
  ./init_common

type
  MemBackendRef* = ref object of TypedBackendRef
    ## Inheriting table so access can be extended for debugging purposes
    tab: Table[Blob,Blob]           ## Structural key-value table

  MemPutHdlRef = ref object of TypedPutHdlRef
    tab: Table[Blob,Blob]

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
    proc(key: openArray[byte]): Result[Blob,KvtError] =
      if key.len == 0:
        return err(KeyInvalid)
      let data = db.tab.getOrVoid @key
      if data.isValid:
        return ok(data)
      err(GetNotFound)

# -------------

proc putBegFn(db: MemBackendRef): PutBegFn =
  result =
    proc(): PutHdlRef =
      db.newSession()

proc putKvpFn(db: MemBackendRef): PutKvpFn =
  result =
    proc(hdl: PutHdlRef; kvps: openArray[(Blob,Blob)]) =
      let hdl = hdl.getSession db
      if hdl.error == KvtError(0):
        for (k,v) in kvps:
          if k.isValid:
            hdl.tab[k] = v
          else:
            hdl.error = KeyInvalid

proc putEndFn(db: MemBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,KvtError] =
      let hdl = hdl.endSession db
      if hdl.error != KvtError(0):
        debug logTxt "putEndFn: key/value failed", error=hdl.error
        return err(hdl.error)

      for (k,v) in hdl.tab.pairs:
        db.tab[k] = v

      ok()

# -------------

proc closeFn(db: MemBackendRef): CloseFn =
  result =
    proc(ignore: bool) =
      discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc memoryBackend*: BackendRef =
  let db = MemBackendRef(
    beKind: BackendMemory)

  db.getKvpFn = getKvpFn db

  db.putBegFn = putBegFn db
  db.putKvpFn = putKvpFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db

  db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walk*(
    be: MemBackendRef;
      ): tuple[key: Blob, data: Blob] =
  ## Walk over all key-value pairs of the database.
  for (key,data) in be.tab.pairs:
    if data.isValid:
      yield (key, data)
    else:
      debug logTxt "walk() skip empty", key

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
