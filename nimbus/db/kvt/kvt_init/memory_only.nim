# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Non persistent constructors for Kvt DB
## ======================================
##
{.push raises: [].}

import
  std/sets,
  results,
  ../kvt_desc,
  ../kvt_desc/desc_backend,
  "."/[init_common, memory_db]

type
  VoidBackendRef* = ref object of TypedBackendRef
    ## Dummy descriptor type, will typically used as `nil` reference

export
  BackendType,
  MemBackendRef

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc newKvtDbRef*(
    backend: static[BackendType];
      ): KvtDbRef =
  ## Simplified prototype for  `BackendNone` and `BackendMemory`  type backend.
  ##
  when backend == BackendVoid:
    KvtDbRef(top: LayerRef())

  elif backend == BackendMemory:
    KvtDbRef(top: LayerRef(), backend: memoryBackend(qidLayout))

  elif backend == BackendRocksDB:
    {.error: "Kvt DB backend \"BackendRocksDB\" needs basePath argument".}

  else:
    {.error: "Unknown/unsupported Kvt DB backend".}

# -----------------

proc finish*(db: KvtDbRef; flush = false) =
  ## Backend destructor. The argument `flush` indicates that a full database
  ## deletion is requested. If set `false` the outcome might differ depending
  ## on the type of backend (e.g. the `BackendMemory` backend will always
  ## flush on close.)
  ##
  ## This distructor may be used on already *destructed* descriptors.
  ##
  if not db.isNil:
    if not db.backend.isNil:
      db.backend.closeFn flush
    db[] = KvtDbObj(top: LayerRef())

# -----------------

proc to*[W: TypedBackendRef|MemBackendRef|VoidBackendRef](
    db: KvtDbRef;
    T: type W;
      ): T =
  ## Handy helper for lew-level access to some backend functionality
  db.backend.T

proc kind*(
    be: BackendRef;
      ): BackendType =
  ## Retrieves the backend type symbol for a `TypedBackendRef` argument where
  ## `BackendVoid` is returned for the`nil` backend.
  if be.isNil:
    BackendVoid
  else:
    be.TypedBackendRef.beKind

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
