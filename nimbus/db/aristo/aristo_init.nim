# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Constructors for Aristo DB
## ==========================
##

{.push raises: [].}

import
  stew/results,
  ./aristo_init/[aristo_init_common, aristo_memory, aristo_rocksdb],
  ./aristo_desc,
  ./aristo_desc/aristo_types_backend

export
  AristoBackendType, AristoStorageType, AristoTypedBackendRef

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type AristoDb;
    backend: static[AristoBackendType];
    basePath: string;
      ): Result[T, AristoError] =
  ## Generic constructor, `basePath` argument is ignored for `BackendNone` and
  ## `BackendMemory`  type backend database. Also, both of these backends
  ## aways succeed initialising.
  when backend == BackendNone:
    ok T(top: AristoLayerRef())

  elif backend == BackendMemory:
    ok T(top: AristoLayerRef(), backend: memoryBackend())

  elif backend == BackendRocksDB:
    let rc = rocksDbBackend basePath
    if rc.isErr:
      return err(rc.error)
    ok T(top: AristoLayerRef(), backend: rc.value)

  else:
    {.error: "Unknown/unsupported Aristo DB backend".}

proc init*(
    T: type AristoDb;
    backend: static[AristoBackendType];
      ): T =
  ## Simplified prototype for  `BackendNone` and `BackendMemory`  type backend.
  when backend == BackendNone:
    T(top: AristoLayerRef())

  elif backend == BackendMemory:
    T(top: AristoLayerRef(), backend: memoryBackend())

  elif backend == BackendRocksDB:
    {.error: "Aristo DB backend \"BackendRocksDB\" needs basePath argument".}

  else:
    {.error: "Unknown/unsupported Aristo DB backend".}

# -----------------

proc finish*(db: var AristoDb; flush = false) =
  ## backend destructor. The argument `flush` indicates that a full database
  ## deletion is requested. If set ot left `false` the outcome might differ
  ## depending on the type of backend (e.g. the `BackendMemory` backend will
  ## always flush on close.)
  if not db.backend.isNil:
    db.backend.closeFn flush
  db.top = AristoLayerRef(nil)
  db.stack.setLen(0)


proc to*[W: MemBackendRef|RdbBackendRef](db: AristoDb; T: type W): T =
  ## Handy helper for lew-level access to some backend functionality
  db.backend.T

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
