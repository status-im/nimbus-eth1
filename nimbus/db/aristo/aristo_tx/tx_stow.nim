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
  ../aristo_delta/delta_merge,
  ".."/[aristo_desc, aristo_delta, aristo_layers]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc txPersistOk*(
    db: AristoDbRef;                  # Database
      ): Result[void,AristoError] =
  if not db.txRef.isNil:
    return err(TxPendingTx)
  if 0 < db.stack.len:
    return err(TxStackGarbled)
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

  if not db.top.isEmpty():
    # Note that `deltaMerge()` will return the `db.top` argument if the
    # `db.balancer` is `nil`. Also, the `db.balancer` is read-only. In the
    # case that there are no forked peers one can ignore that restriction as
    # no balancer is shared.
    db.balancer = deltaMerge(db.top, db.balancer)

    # New empty top layer
    db.top = LayerRef(vTop: db.balancer.vTop)

  # Merge/move `balancer` into persistent tables (unless missing)
  ? db.deltaPersistent nxtSid

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
