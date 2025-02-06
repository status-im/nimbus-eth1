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
  std/tables,
  results,
  ../kvt_delta/delta_merge,
  ".."/[kvt_desc, kvt_delta]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txPersistOk*(
    db: KvtDbRef;                     # Database
      ): Result[void,KvtError] =
  ## Verify that `txPersist()` can go ahead
  if not db.txRef.isNil:
    return err(TxPendingTx)
  if 0 < db.stack.len:
    return err(TxStackGarbled)
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

  if 0 < db.top.sTab.len:
    # Note that `deltaMerge()` will return the `db.top` argument if the
    # `db.balancer` is `nil`. Also, the `db.balancer` is read-only. In the
    # case that there are no forked peers one can ignore that restriction as
    # no balancer is shared.
    db.balancer = deltaMerge(db.top, db.balancer)

    # New empty top layer
    db.top = LayerRef()

  # Move `balancer` data into persistent tables
  ? db.deltaPersistent()

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
