# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  memory_only,
  aristo_desc

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type AristoDbRef;
    B: type RdbBackendRef;
    opts: DbOptions;
    baseDb: RocksDbInstanceRef;
      ): Result[T, AristoError] =
  let
    be = rocksDbBackend(opts, baseDb)
    vTop = block:
      let rc = be.getTuvFn()
      if rc.isErr:
        be.closeFn(eradicate = false)
        return err(rc.error)
      rc.value
    db = AristoDbRef(
      txRef: AristoTxRef(layer: LayerRef(vTop: vTop, cTop: vTop)),
      backend: be,
      accLeaves: LruCache[Hash32, VertexRef].init(ACC_LRU_SIZE),
      stoLeaves: LruCache[Hash32, VertexRef].init(ACC_LRU_SIZE),
    )

  db.txRef.db = db # TODO evaluate if this cyclic ref is worth the convenience

  ok(db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
