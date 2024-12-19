# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  results,
  ".."/[kvt_desc, kvt_delta]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txPersistOk*(
    db: KvtDbRef;                     # Database
      ): Result[void,KvtError] =
  ## Verify that `txPersist()` can go ahead
  if not db.deltaPersistentOk():
    return err(TxBackendNotWritable)
  ok()

proc txPersist*(
    db: KvtDbRef;                     # Database
      ): Result[void,KvtError] =
  ## The function saves the data from the top layer cache into the
  ## backend database.
  ##
  ## If there is no backend the function returns immediately with an error.
  ## The same happens if there is a pending transaction.
  ##
  ? db.txPersistOk()

  # Move `txRef` data into persistent tables
  ? db.deltaPersistent()

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
