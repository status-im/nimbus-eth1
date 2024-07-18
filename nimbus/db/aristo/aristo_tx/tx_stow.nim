# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Transaction stow/save helper
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

proc txStowOk*(
    db: AristoDbRef;                  # Database
    persistent: bool;                 # Stage only unless `true`
      ): Result[void,AristoError] =
  if not db.txRef.isNil:
    return err(TxPendingTx)
  if 0 < db.stack.len:
    return err(TxStackGarbled)
  if persistent and not db.deltaPersistentOk():
    return err(TxBackendNotWritable)
  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txStow*(
    db: AristoDbRef;                  # Database
    nxtSid: uint64;                   # Next state ID (aka block number)
    persistent: bool;                 # Stage only unless `true`
      ): Result[void,AristoError] =
  ## Worker for `stow()` and `persist()` variants.
  ##
  ? db.txStowOk persistent

  if not db.top.isEmpty():
    # Note that `deltaMerge()` will return the 1st argument if the 2nd is `nil`
    db.balancer = db.deltaMerge(db.top, db.balancer).valueOr:
      return err(error[1])

    # New empty top layer
    db.top = LayerRef(vTop: db.balancer.vTop)

  if persistent:
    # Merge/move `balancer` into persistent tables (unless missing)
    ? db.deltaPersistent nxtSid

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
