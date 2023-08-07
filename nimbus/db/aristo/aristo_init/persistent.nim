# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  ../aristo_desc,
  "."/[aristo_init_common, aristo_rocksdb, memory_only]

export
  memory_only

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc newAristoDbRef*(
    backend: static[AristoBackendType];
    basePath: string;
      ): Result[AristoDbRef, AristoError] =
  ## Generic constructor, `basePath` argument is ignored for `BackendNone` and
  ## `BackendMemory`  type backend database. Also, both of these backends
  ## aways succeed initialising.
  when backend == BackendRocksDB:
    let be = block:
      let rc = rocksDbBackend basePath
      if rc.isErr:
        return err(rc.error)
      rc.value
    let vGen = block:
      let rc = be.getIdgFn()
      if rc.isErr:
        be.closeFn(flush = false)
        return err(rc.error)
      rc.value
    ok AristoDbRef(top: AristoLayerRef(vGen: vGen), backend: be)

  elif backend == BackendNone:
    {.error: "Use BackendNone.init() without path argument".}

  elif backend == BackendMemory:
    {.error: "Use BackendMemory.init() without path argument".}

  else:
    {.error: "Unknown/unsupported Aristo DB backend".}

# -----------------

proc to*[W: RdbBackendRef](
    db: AristoDbRef;
    T: type W;
      ): T =
  ## Handy helper for lew-level access to some backend functionality
  db.backend.T

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
