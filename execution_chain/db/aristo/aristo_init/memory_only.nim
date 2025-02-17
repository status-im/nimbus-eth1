# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  GuestDbRef,
  MemBackendRef

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
    B: type MemOnlyBackend;                   # Backend type
      ): T =
  ## Memory backend constructor.
  ##

  when B is VoidBackendRef:
    AristoDbRef.init(nil)[]

  elif B is MemBackendRef:
    AristoDbRef.init(memoryBackend())[]
  else:
    raiseAssert "Unknown backend"

proc init*(
    T: type AristoDbRef;                      # Target type
      ): T =
  ## Shortcut for `AristoDbRef.init(VoidBackendRef)`
  AristoDbRef.init VoidBackendRef

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
