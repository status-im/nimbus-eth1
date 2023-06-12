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
## For a backend-less constructor use `AristoDb(top: AristoLayerRef())`.

{.push raises: [].}

import
  ./aristo_init/[aristo_memory],
  ./aristo_desc,
  ./aristo_desc/aristo_types_private

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(key: var HashKey; data: openArray[byte]): bool =
  ## Import argument `data` into `key` which must have length either `32`, or
  ## `0`. The latter case is equivalent to an all zero byte array of size `32`.
  if data.len == 32:
    (addr key.ByteArray32[0]).copyMem(unsafeAddr data[0], data.len)
    return true
  if data.len == 0:
    key = VOID_HASH_KEY
    return true

proc init*(T: type AristoDb): T =
  ## Constructor with memory backend.
  T(top:     AristoLayerRef(),
    backend: memoryBackend())

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
