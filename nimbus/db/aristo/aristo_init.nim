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

proc init*(T: type AristoDbRef): T =
  ## Constructor with memory backend.
  T(cascaded: false, backend: memoryBackend())

proc init*(T: type AristoDbRef; db: T): T =
  ## Cascaded constructor, a new layer is pushed and returned.
  result = T(
    cascaded: true,
    lRoot:    db.lRoot,
    vGen:     db.vGen,
    stack:    db)
  if db.cascaded:
    result.level = db.level + 1
    result.base = db.base
  else:
    result.level = 1
    result.base = db

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
