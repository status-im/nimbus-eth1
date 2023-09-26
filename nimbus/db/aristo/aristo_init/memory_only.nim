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
  ../aristo_desc,
  ../aristo_desc/desc_backend,
  "."/[init_common, memory_db]

type
  VoidBackendRef* = ref object of TypedBackendRef
    ## Dummy descriptor type, used as `nil` reference

  MemOnlyBackend* = VoidBackendRef|MemBackendRef

export
  BackendType,
  MemBackendRef,
  QidLayoutRef

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

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
    T: type AristoDbRef;                      # Target type
    B: type MemBackendRef;                    # Backend type
    qidLayout: QidLayoutRef;                  # Optional fifo schedule
      ): T =
  ## Memory backend constructor.
  ##
  ## If the `qidLayout` argument is set `QidLayoutRef(nil)`, the a backend
  ## database will not provide filter history management. Providing a different
  ## scheduler layout shoud be used with care as table access with different
  ## layouts might render the filter history data unmanageable.
  ##
  when B is MemBackendRef:
    AristoDbRef(top: LayerRef(), backend: memoryBackend(qidLayout))

proc init*(
    T: type AristoDbRef;                      # Target type
    B: type MemOnlyBackend;                   # Backend type
      ): T =
  ## Memory backend constructor.
  ##
  ## If the `qidLayout` argument is set `QidLayoutRef(nil)`, the a backend
  ## database will not provide filter history management. Providing a different
  ## scheduler layout shoud be used with care as table access with different
  ## layouts might render the filter history data unmanageable.
  ##
  when B is VoidBackendRef:
    AristoDbRef(top: LayerRef())

  elif B is MemBackendRef:
    let qidLayout = DEFAULT_QID_QUEUES.to(QidLayoutRef)
    AristoDbRef(top: LayerRef(), backend: memoryBackend(qidLayout))

proc init*(
    T: type AristoDbRef;                      # Target type
      ): T =
  ## Shortcut for `AristoDbRef.init(VoidBackendRef)`
  AristoDbRef.init VoidBackendRef


proc finish*(db: AristoDbRef; flush = false) =
  ## Backend destructor. The argument `flush` indicates that a full database
  ## deletion is requested. If set `false` the outcome might differ depending
  ## on the type of backend (e.g. the `BackendMemory` backend will always
  ## flush on close.)
  ##
  ## In case of distributed descriptors accessing the same backend, all
  ## distributed descriptors will be destroyed.
  ##
  ## This distructor may be used on already *destructed* descriptors.
  ##
  if not db.isNil:
    if not db.backend.isNil:
      db.backend.closeFn flush

    let lebo = db.getCentre
    discard lebo.forgetOthers()
    lebo[] = AristoDbObj(top: LayerRef())

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
