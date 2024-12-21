# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Transaction save helper
## =========================================
##
{.push raises: [].}

import
  results,
  ../[aristo_desc, aristo_delta]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc txPersistOk*(
    db: AristoDbRef;                  # Database
      ): Result[void,AristoError] =
  if not db.deltaPersistentOk():
    return err(TxBackendNotWritable)
  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txPersist*(
    db: AristoDbRef;                  # Database
    nxtSid: uint64;                   # Next state ID (aka block number)
      ): Result[void,AristoError] =
  ## Worker for `persist()` variants.
  ##
  ? db.txPersistOk()

  # Merge/move `txRef` into persistent tables (unless missing)
  ? db.deltaPersistent nxtSid

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
