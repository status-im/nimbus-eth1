# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Transaction stow/save helper
## ======================================
##
{.push raises: [].}

import
  std/tables,
  results,
  ".."/[kvt_desc, kvt_delta]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txStowOk*(
    db: KvtDbRef;                     # Database
    persistent: bool;                 # Stage only unless `true`
      ): Result[void,KvtError] =
  ## Verify that `txStow()` can go ahead
  if not db.txRef.isNil:
    return err(TxPendingTx)
  if 0 < db.stack.len:
    return err(TxStackGarbled)

  if persistent and not db.deltaUpdateOk():
    return err(TxBackendNotWritable)

  ok()

proc txStow*(
    db: KvtDbRef;                     # Database
    persistent: bool;                 # Stage only unless `true`
      ): Result[void,KvtError] =
  ## The function saves the data from the top layer cache into the
  ## backend database.
  ##
  ## If there is no backend the function returns immediately with an error.
  ## The same happens if there is a pending transaction.
  ##
  ? db.txStowOk persistent

  if 0 < db.top.delta.sTab.len:
    db.deltaMerge db.top.delta
    db.top.delta = LayerDeltaRef()

  if persistent:
    # Move `balancer` data into persistent tables
    ? db.deltaUpdate()

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
