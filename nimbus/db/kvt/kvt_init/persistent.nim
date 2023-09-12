# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  "."/[init_common, rocks_db, memory_only]
export
  RdbBackendRef,
  memory_only

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc newKvtDbRef*(
    backend: static[BackendType];
    basePath: string;
      ): Result[KvtDbRef,KvtError] =
  ## Generic constructor, `basePath` argument is ignored for `BackendNone` and
  ## `BackendMemory`  type backend database. Also, both of these backends
  ## aways succeed initialising.
  ##
  when backend == BackendRocksDB:
    ok KvtDbRef(top: LayerRef(vGen: vGen), backend: ? rocksDbBackend basePath)

  elif backend == BackendVoid:
    {.error: "Use BackendNone.init() without path argument".}

  elif backend == BackendMemory:
    {.error: "Use BackendMemory.init() without path argument".}

  else:
    {.error: "Unknown/unsupported Kvt DB backend".}

# -----------------

proc to*[W: RdbBackendRef](
    db: KvtDbRef;
    T: type W;
      ): T =
  ## Handy helper for lew-level access to some backend functionality
  db.backend.T

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
