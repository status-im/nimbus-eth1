# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Non persistent constructors for Aristo DB
## =========================================
##
{.push raises: [].}

import
  std/sets,
  results,
  ../aristo_desc,
  ../aristo_desc/aristo_types_backend,
  "."/[aristo_init_common, aristo_memory]

type
  VoidBackendRef* = ref object of TypedBackendRef
    ## Dummy descriptor type, will typically used as `nil` reference

export
  AristoBackendType,
  VoidBackendRef,
  MemBackendRef,
  TypedBackendRef

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc newAristoDbRef*(
    backend: static[AristoBackendType];
      ): AristoDbRef =
  ## Simplified prototype for  `BackendNone` and `BackendMemory`  type backend.
  when backend == BackendVoid:
    AristoDbRef(top: AristoLayerRef())

  elif backend == BackendMemory:
    AristoDbRef(top: AristoLayerRef(), backend: memoryBackend())

  elif backend == BackendRocksDB:
    {.error: "Aristo DB backend \"BackendRocksDB\" needs basePath argument".}

  else:
    {.error: "Unknown/unsupported Aristo DB backend".}

# -----------------

proc finish*(db: AristoDbRef; flush = false) =
  ## Backend destructor. The argument `flush` indicates that a full database
  ## deletion is requested. If set ot left `false` the outcome might differ
  ## depending on the type of backend (e.g. the `BackendMemory` backend will
  ## always flush on close.)
  ##
  ## In case of distributed descriptors accessing the same backend, all
  ## distributed descriptors will be destroyed.
  ##
  ## This distructor may be used on already *destructed* descriptors.
  ##
  if not db.isNil:
    if not db.backend.isNil:
      db.backend.closeFn flush

    if db.dudes.isNil:
      db[] = AristoDbObj()
    else:
      let lebo = if db.dudes.rwOk: db else: db.dudes.rwDb
      for w in lebo.dudes.roDudes:
        w[] = AristoDbObj()
      lebo[] = AristoDbObj()

# -----------------

proc to*[W: TypedBackendRef|MemBackendRef|VoidBackendRef](
    db: AristoDbRef;
    T: type W;
      ): T =
  ## Handy helper for lew-level access to some backend functionality
  db.backend.T

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
