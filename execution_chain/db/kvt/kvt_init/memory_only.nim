# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  ./memory_db

export
  MemBackendRef

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(T: type KvtDbRef): T =
  ## Memory backend constructor.
  ##
  let db = memoryBackend()
  db.txRef = KvtTxRef(db: db)
  db

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
