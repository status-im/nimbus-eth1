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
  ./aristo_init/[aristo_init_common, aristo_memory],
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
      ): T =
  ## Prototype for creating `BackendNone` and `BackendMemory`  type backend.
  when backend == BackendNone:
    T(top: AristoLayerRef())

  elif backend == BackendMemory:
    T(top: AristoLayerRef(), backend: memoryBackend())

  else:
    {.error: "Unknown/unsupported Aristo DB backend".}

# -----------------

proc finish*(db: var AristoDb) =
  if not db.backend.isNil:
    db.backend.closeFn()
  db.top = AristoLayerRef(nil)
  db.stack.setLen(0)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
