# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocksdb backend for Kvt DB
## ==========================
##
## The iterators provided here are currently available only by direct
## backend access
## ::
##   import
##     kvt/kvt_init,
##     kvt/kvt_init/kvt_rocksdb
##
##   let rc = KvtDb.init(BackendRocksDB, "/var/tmp")
##   if rc.isOk:
##     let be = rc.value.to(RdbBackendRef)
##     for (n, key, vtx) in be.walkVtx:
##       ...
##
{.push raises: [].}

import
  chronicles,
  rocksdb,
  results,
  ../../aristo/aristo_init/persistent,
  ../../opts,
  ../kvt_desc,
  ../kvt_desc/desc_backend,
  ../kvt_tx/tx_stow,
  ./init_common,
  ./rocks_db/[rdb_desc, rdb_get, rdb_init, rdb_put, rdb_walk]

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

type
  RdbBackendRef* = ref object of TypedBackendRef
    rdb: RdbInst              ## Allows low level access to database

  RdbPutHdlRef = ref object of TypedPutHdlRef

logScope:
  topics = "kvt-backend"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "RocksDB " & info


proc newSession(db: RdbBackendRef): RdbPutHdlRef =
  new result
  result.TypedPutHdlRef.beginSession db

proc getSession(hdl: PutHdlRef; db: RdbBackendRef): RdbPutHdlRef =
  hdl.TypedPutHdlRef.verifySession db
  hdl.RdbPutHdlRef

proc endSession(hdl: PutHdlRef; db: RdbBackendRef): RdbPutHdlRef =
  hdl.TypedPutHdlRef.finishSession db
  hdl.RdbPutHdlRef

# ------------------------------------------------------------------------------
# Private functions: standard interface
# ------------------------------------------------------------------------------

proc getKvpFn(db: RdbBackendRef): GetKvpFn =
  result =
    proc(key: openArray[byte]): Result[seq[byte],KvtError] =

      # Get data record
      var data = db.rdb.get(key).valueOr:
        when extraTraceMessages:
          debug logTxt "getKvpFn() failed", key, error=error[0], info=error[1]
        return err(error[0])

      # Return if non-empty
      if 0 < data.len:
        return ok(move(data))

      err(GetNotFound)

proc lenKvpFn(db: RdbBackendRef): LenKvpFn =
  result =
    proc(key: openArray[byte]): Result[int,KvtError] =

      # Get data record
      var len = db.rdb.len(key).valueOr:
        when extraTraceMessages:
          debug logTxt "lenKvpFn() failed", key, error=error[0], info=error[1]
        return err(error[0])

      # Return if non-empty
      if 0 < len:
        return ok(len)

      err(GetNotFound)

# -------------

proc putBegFn(db: RdbBackendRef): PutBegFn =
  result =
    proc(): Result[PutHdlRef,KvtError] =
      db.rdb.begin()
      ok db.newSession()


proc putKvpFn(db: RdbBackendRef): PutKvpFn =
  result =
    proc(hdl: PutHdlRef; k, v: openArray[byte]) =
      let hdl = hdl.getSession db
      if hdl.error == KvtError(0):

        # Collect batch session arguments
        db.rdb.put(k, v).isOkOr:
          hdl.error = error[0]
          hdl.info = error[1]
          return


proc putEndFn(db: RdbBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,KvtError] =
      let hdl = hdl.endSession db
      if hdl.error != KvtError(0):
        when extraTraceMessages:
          debug logTxt "putEndFn: failed", error=hdl.error, info=hdl.info
        db.rdb.rollback()
        return err(hdl.error)

      # Commit session
      db.rdb.commit().isOkOr:
        when extraTraceMessages:
          trace logTxt "putEndFn: failed", error=($error[0]), info=error[1]
        return err(error[0])
      ok()


proc closeFn(db: RdbBackendRef): CloseFn =
  result =
    proc(eradicate: bool) =
      db.rdb.destroy(eradicate)

proc setWrReqFn(db: RdbBackendRef): SetWrReqFn =
  result =
    proc(kvt: RootRef): Result[void,KvtError] =
      err(RdbBeHostNotApplicable)

# ------------------------------------------------------------------------------
# Private functions: triggered interface changes
# ------------------------------------------------------------------------------

proc putBegTriggeredFn(db: RdbBackendRef): PutBegFn =
  ## Variant of `putBegFn()` for piggyback write batch
  result =
    proc(): Result[PutHdlRef,KvtError] =
      # Check whether somebody else initiated the rocksdb write batch/session
      if db.rdb.session.isNil:
        const error = RdbBeDelayedNotReady
        when extraTraceMessages:
          debug logTxt "putBegTriggeredFn: failed", error
        return err(error)
      ok db.newSession()

proc putEndTriggeredFn(db: RdbBackendRef): PutEndFn =
  ## Variant of `putEndFn()` for piggyback write batch
  result =
    proc(hdl: PutHdlRef): Result[void,KvtError] =

      # There is no commit()/rollback() here as we do not own the backend.
      let hdl = hdl.endSession db

      if hdl.error != KvtError(0):
        when extraTraceMessages:
          debug logTxt "putEndTriggeredFn: failed",
            error=hdl.error, info=hdl.info
        # The error return code will signal a problem to the `txPersist()`
        # function which was called by `writeEvCb()` below.
        return err(hdl.error)

      # Commit the session. This will be acknowledged by the `txPersist()`
      # function which was called by `writeEvCb()` below.
      ok()

proc closeTriggeredFn(db: RdbBackendRef): CloseFn =
  ## Variant of `closeFn()` for piggyback write batch
  result =
    proc(eradicate: bool) =
      # Nothing to do here as we do not own the backend
      discard

proc setWrReqTriggeredFn(db: RdbBackendRef): SetWrReqFn =
  result =
    proc(kvt: RootRef): Result[void,KvtError] =
      if db.rdb.delayedPersist.isNil:
        db.rdb.delayedPersist = KvtDbRef(kvt)
        ok()
      else:
        err(RdbBeDelayedAlreadyRegistered)

# ------------------------------------------------------------------------------
# Private function: trigger handler
# ------------------------------------------------------------------------------

proc writeEvCb(db: RdbBackendRef): RdbWriteEventCb =
  ## Write session event handler
  result =
    proc(ws: WriteBatchRef): bool =

      # Only do something if a write session request was queued
      if not db.rdb.delayedPersist.isNil:
        defer:
          # Clear session environment when leaving. This makes sure that the
          # same session can only be run once.
          db.rdb.session = WriteBatchRef(nil)
          db.rdb.delayedPersist = KvtDbRef(nil)

        # Publish session argument
        db.rdb.session = ws

        # Execute delayed session. Note the the `txPersist()` function is located
        # in `tx_stow.nim`. This module `tx_stow.nim` is also imported by
        # `kvt_tx.nim` which contains `persist() `. So the logic goes:
        # ::
        #   kvt_tx.persist()     --> registers a delayed write request rather
        #                            than excuting tx_stow.txPersist()
        #
        #   // the backend owner (i.e. Aristo) will start a write cycle and
        #   // invoke the envent handler rocks_db.writeEvCb()
        #   rocks_db.writeEvCb() --> calls tx_stow.txPersist()
        #
        #   tx_stow.txPersist()     --> calls rocks_db.putBegTriggeredFn()
        #                            calls rocks_db.putKvpFn()
        #                            calls rocks_db.putEndTriggeredFn()
        #
        let rc = db.rdb.delayedPersist.txPersist()
        if rc.isErr:
          error "writeEventCb(): persist() failed", error=rc.error
          return false
      true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rocksDbKvtBackend*(
    path: string;
    dbOpts: DbOptionsRef;
    cfOpts: ColFamilyOptionsRef;
      ): Result[BackendRef,(KvtError,string)] =
  let db = RdbBackendRef(
    beKind: BackendRocksDB)

  # Initialise RocksDB
  db.rdb.init(path, dbOpts, cfOpts).isOkOr:
    when extraTraceMessages:
      trace logTxt "constructor failed", error=error[0], info=error[1]
    return err(error)

  db.getKvpFn = getKvpFn db
  db.lenKvpFn = lenKvpFn db

  db.putBegFn = putBegFn db
  db.putKvpFn = putKvpFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db
  db.setWrReqFn = setWrReqFn db
  ok db


proc rocksDbKvtTriggeredBackend*(
    adb: AristoDbRef;
    oCfs: openArray[ColFamilyReadWrite];
      ): Result[BackendRef,(KvtError,string)] =
  let db = RdbBackendRef(
    beKind: BackendRdbTriggered)

  # Initialise RocksDB piggy-backed on `Aristo` backend.
  db.rdb.init(oCfs).isOkOr:
    when extraTraceMessages:
      trace logTxt "constructor failed", error=error[0], info=error[1]
    return err(error)

  # Register write session event handler
  adb.activateWrTrigger(db.writeEvCb()).isOkOr:
    return err((RdbBeHostError,$error))

  db.getKvpFn = getKvpFn db
  db.lenKvpFn = lenKvpFn db

  db.putBegFn = putBegTriggeredFn db
  db.putKvpFn = putKvpFn db
  db.putEndFn = putEndTriggeredFn db

  db.closeFn = closeTriggeredFn db
  db.setWrReqFn = setWrReqTriggeredFn db
  ok db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walk*(
    be: RdbBackendRef;
      ): tuple[key: seq[byte], data: seq[byte]] =
  ## Walk over all key-value pairs of the database.
  ##
  for (k,v) in be.rdb.walk:
    yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
