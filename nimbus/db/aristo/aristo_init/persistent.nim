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
  ../aristo_desc,
  ./rocks_db/rdb_desc,
  "."/[rocks_db, memory_only],
  ../../opts

export
  RdbBackendRef,
  memory_only

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc newAristoRdbDbRef(
    basePath: string;
    qidLayout: QidLayoutRef;
    opts: DbOptions
      ): Result[AristoDbRef, AristoError]=
  let
    be = ? rocksDbBackend(basePath, qidLayout, opts)
    vGen = block:
      let rc = be.getIdgFn()
      if rc.isErr:
        be.closeFn(flush = false)
        return err(rc.error)
      rc.value
  ok AristoDbRef(
    top: LayerRef(
      delta: LayerDeltaRef(),
      final: LayerFinalRef(vGen: vGen)),
    backend: be)

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*[W: RdbBackendRef](
    T: type AristoDbRef;
    B: type W;
    basePath: string;
    qidLayout: QidLayoutRef;
    opts: DbOptions
      ): Result[T, AristoError] =
  ## Generic constructor, `basePath` argument is ignored for memory backend
  ## databases (which also unconditionally succeed initialising.)
  ##
  ## If the `qidLayout` argument is set `QidLayoutRef(nil)`, the a backend
  ## database will not provide filter history management. Providing a different
  ## scheduler layout shoud be used with care as table access with different
  ## layouts might render the filter history data unmanageable.
  ##
  when B is RdbBackendRef:
    basePath.newAristoRdbDbRef qidLayout, opts

proc init*[W: RdbBackendRef](
    T: type AristoDbRef;
    B: type W;
    basePath: string;
    opts: DbOptions
      ): Result[T, AristoError] =
  ## Variant of `init()` using default schedule.
  ##
  when B is RdbBackendRef:
    basePath.newAristoRdbDbRef DEFAULT_QID_QUEUES.to(QidLayoutRef), opts

proc getRocksDbFamily*(
    gdb: GuestDbRef;
    instance = 0;
      ): Result[ColFamilyReadWrite,void] =
  ## Database pigiback feature
  if not gdb.isNil and gdb.beKind == BackendRocksDB:
    return ok RdbGuestDbRef(gdb).guestDb
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
