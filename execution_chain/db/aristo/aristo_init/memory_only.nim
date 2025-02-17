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
  doAssert(not be.isNil)
  be.TypedBackendRef.beKind

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type AristoDbRef;                     # Target type
    B: type MemBackendRef;                   # Backend type
      ): T =
  ## Memory backend constructor.
  ##
  AristoDbRef.init(memoryBackend())[]

proc init*(T: type AristoDbRef): T =
  AristoDbRef.init(MemBackendRef)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
