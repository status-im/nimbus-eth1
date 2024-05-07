# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  ../kvt_desc,
  ../kvt_desc/desc_backend,
  "."/[init_common, memory_db]

type
  VoidBackendRef* = ref object of TypedBackendRef
    ## Dummy descriptor type, used as `nil` reference

  MemOnlyBackend* = VoidBackendRef|MemBackendRef

export
  BackendType,
  MemBackendRef

# ------------------------------------------------------------------------------
# Public helpers
# -----------------------------------------------------------------------------

proc kind*(
    be: BackendRef;
      ): BackendType =
  ## Retrieves the backend type symbol for a `be` backend database argument
  ## where `BackendVoid` is returned for the`nil` backend.
  if be.isNil:
    BackendVoid
  else:
    be.TypedBackendRef.beKind

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type KvtDbRef;                         # Target type
    B: type MemOnlyBackend;                   # Backend type
      ): T =
  ## Memory backend constructor.
  ##
  when B is VoidBackendRef:
    KvtDbRef(top: LayerRef.init())

  elif B is MemBackendRef:
    KvtDbRef(top: LayerRef.init(), backend: memoryBackend())

proc init*(
    T: type KvtDbRef;                         # Target type
      ): T =
  ## Shortcut for `KvtDbRef.init(VoidBackendRef)`
  KvtDbRef.init VoidBackendRef
 

proc finish*(db: KvtDbRef; flush = false) =
  ## Backend destructor. The argument `flush` indicates that a full database
  ## deletion is requested. If set `false` the outcome might differ depending
  ## on the type of backend (e.g. the `BackendMemory` backend will always
  ## flush on close.)
  ##
  ## This distructor may be used on already *destructed* descriptors.
  ##
  if not db.backend.isNil:
    db.backend.closeFn flush
  discard db.getCentre.forgetOthers()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
