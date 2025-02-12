# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Transaction save helper
## ======================================
##
{.push raises: [].}

import
  ./[kvt_desc, kvt_tx_frame]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc persist*(
    db: KvtDbRef;                     # Database
    batch: PutHdlRef;
      ) =
  ## Persistently store data onto backend database. If the system is running
  ## without a database backend, the function returns immediately with an
  ## error.
  ##
  ## The function merges all staged data from the top layer cache onto the
  ## backend stage area. After that, the top layer cache is cleared.
  ##
  ## Finally, the staged data are merged into the physical backend database
  ## and the staged data area is cleared. Wile performing this last step,
  ## the recovery journal is updated (if available.)
  ##
  db.txFramePersist(batch)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
