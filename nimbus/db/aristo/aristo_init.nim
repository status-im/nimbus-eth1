# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Backend or cascaded constructors for Aristo DB
## ==============================================
##
## For a backend-less constructor use `AristoDbRef.new()`

{.push raises: [].}

import
  ./aristo_init/[aristo_memory],
  ./aristo_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(T: type AristoDb): T =
  ## Constructor with memory backend.
  T(top:     AristoLayerRef(),
    backend: memoryBackend())

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
