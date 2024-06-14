# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Persistent constructor for Aristo DB
## ====================================
##
## This module automatically pulls in the persistent backend library at the
## linking stage (e.g. `rocksdb`) which can be avoided for pure memory DB
## applications by importing `./aristo_init/memory_only` (rather than
## `./aristo_init/persistent`.)
##
{.push raises: [].}

import
  results,
  rocksdb,
  ../../opts,
  ../aristo_desc,
  ./rocks_db/rdb_desc,
  "."/[rocks_db, memory_only]

export
  AristoDbRef,
  RdbBackendRef,
  RdbWriteEventCb,
  memory_only

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc newAristoRdbDbRef(
    basePath: string;
    opts: DbOptions;
      ): Result[AristoDbRef, AristoError]=
  let
    be = ? rocksDbBackend(basePath, opts)
    vTop = block:
      let rc = be.getTuvFn()
      if rc.isErr:
        be.closeFn(eradicate = false)
        return err(rc.error)
      rc.value
  ok AristoDbRef(
    top: LayerRef(
      delta: LayerDeltaRef(vTop: vTop),
      final: LayerFinalRef()),
    backend: be)

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type AristoDbRef;
    B: type RdbBackendRef;
    basePath: string;
    opts: DbOptions
      ): Result[T, AristoError] =
  ## Generic constructor, `basePath` argument is ignored for memory backend
  ## databases (which also unconditionally succeed initialising.)
  ##
  basePath.newAristoRdbDbRef opts

proc reinit*(
    db: AristoDbRef;
    cfs: openArray[ColFamilyDescriptor];
      ): Result[seq[ColFamilyReadWrite],AristoError] =
  ## Re-initialise the `RocksDb` backend database with additional or changed
  ## column family settings. This can be used to make space for guest use of
  ## the backend used by `Aristo`. The function returns a list of column family
  ## descriptors in the same order as the `cfs` argument.
  ##
  ## The argument `cfs` list replaces and extends the CFs already on disk by
  ## its options except for the ones defined for use with `Aristo`.
  ##
  ## Even though tx layers and filters might not be affected by this function,
  ## it is prudent to have them clean and saved on the backend database before
  ## changing it. On error conditions, data might get lost.
  ##
  case db.backend.kind:
  of BackendRocksDB:
    db.backend.rocksDbUpdateCfs cfs
  of BackendRdbHosting:
    err(RdbBeWrTriggerActiveAlready)
  else:
    return err(RdbBeTypeUnsupported)

proc activateWrTrigger*(
    db: AristoDbRef;
    hdl: RdbWriteEventCb;
      ): Result[void,AristoError] =
  ## This function allows to link an application to the `Aristo` storage event
  ## for the `RocksDb` backend via call back argument function `hdl`.
  ##
  ## The argument handler `hdl` of type
  ## ::
  ##    proc(session: WriteBatchRef): bool
  ##
  ## will be invoked when a write batch for the `Aristo` database is opened in
  ## order to save current changes to the backend. The `session` argument passed
  ## to the handler in conjunction with a list of `ColFamilyReadWrite` items
  ## (as returned from `reinit()`) might be used to store additional items
  ## to the database with the same write batch.
  ##
  ## If the handler returns `true` upon return from running, the write batch
  ## will proceed saving. Otherwise it is aborted and no data are saved at all.
  ##
  case db.backend.kind:
  of BackendRocksDB:
    db.backend.rocksDbSetEventTrigger hdl
  of BackendRdbHosting:
    err(RdbBeWrTriggerActiveAlready)
  else:
    err(RdbBeTypeUnsupported)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
