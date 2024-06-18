# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Persistent constructor for Kvt DB
## ====================================
##
## This module automatically pulls in the persistent backend library at the
## linking stage (e.g. `rocksdb`) which can be avoided for pure memory DB
## applications by importing `./kvt_init/memory_only` (rather than
## `./kvt_init/persistent`.)
##
{.push raises: [].}

import
  rocksdb,
  results,
  ../../aristo,
  ../../opts,
  ../kvt_desc,
  "."/[rocks_db, memory_only]

export
  RdbBackendRef,
  memory_only

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toErr0(err: (KvtError,string)): KvtError =
  err[0]

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type KvtDbRef;
    B: type RdbBackendRef;
    basePath: string;
    dbOpts: DbOptionsRef;
    cfOpts: ColFamilyOptionsRef;
      ): Result[KvtDbRef,KvtError] =
  ## Generic constructor for `RocksDb` backend
  ##
  ok KvtDbRef(
    top: LayerRef.init(),
    backend: ? rocksDbKvtBackend(basePath, dbOpts, cfOpts).mapErr toErr0)

proc init*(
    T: type KvtDbRef;
    B: type RdbBackendRef;
    adb: AristoDbRef;
    oCfs: openArray[ColFamilyReadWrite];
      ): Result[KvtDbRef,KvtError] =
  ## Constructor for `RocksDb` backend which piggybacks on the `Aristo`
  ## backend. The following changes will occur after successful instantiation:
  ##
  ## * When invoked, the function `kvt_tx.persistent()` will always return an
  ##   error. If everything is all right (e.g. saving is possible), the error
  ##   returned will be `TxPersistDelayed`. This indicates that the save
  ##   request was queued, waiting for being picked up by an event handler.
  ##
  ## * There should be an invocation of `aristo_tx.persistent()` immediately
  ##   follwing the `kvt_tx.persistent()` call (some `KVT` functions might
  ##   return `RdbBeDelayedLocked` or similar errors while the save request
  ##   is pending.) Once successful, the`aristo_tx.persistent()` function will
  ##   also have commited the pending save request mentioned above.
  ##
  ## * The function `kvt_init/memory_only.finish()` does nothing.
  ##
  ## * The function `aristo_init/memory_only.finish()` will close both
  ##   sessions, the one for `KVT` and the other for `Aristo`.
  ##
  ## * The functiond `kvt_delta.deltaUpdate()` and `tx_stow.tcStow()` should
  ##   not be invoked directly (they will stop with an error most of the time,
  ##   anyway.)
  ##
  ok KvtDbRef(
    top: LayerRef.init(),
    backend: ? rocksDbKvtTriggeredBackend(adb, oCfs).mapErr toErr0)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
