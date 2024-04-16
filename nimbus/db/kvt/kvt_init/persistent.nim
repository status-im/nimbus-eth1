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
  results,
  ../kvt_desc,
  "."/[rocks_db, memory_only]

from ../../aristo/aristo_persistent
  import GuestDbRef, getRocksDbFamily

export
  RdbBackendRef,
  memory_only

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*[W: MemOnlyBackend|RdbBackendRef](
    T: type KvtDbRef;
    B: type W;
    basePath: string;
    guestDb = GuestDbRef(nil);
      ): Result[KvtDbRef,KvtError] =
  ## Generic constructor, `basePath` argument is ignored for `BackendNone` and
  ## `BackendMemory`  type backend database. Also, both of these backends
  ## aways succeed initialising.
  ##
  ## If the argument `guestDb` is set and is a RocksDB column familly, the
  ## `Kvt`batabase is built upon this column familly. Othewise it is newly
  ## created with `basePath` as storage location.
  ##
  when B is RdbBackendRef:
    let rc = guestDb.getRocksDbFamily()
    if rc.isOk:
      ok KvtDbRef(top: LayerRef(), backend: ? rocksDbBackend rc.value)
    else:
      ok KvtDbRef(top: LayerRef(), backend: ? rocksDbBackend basePath)

  else:
    ok KvtDbRef.init B

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
