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
  std/[sequtils, tables],
  results,
  ../kvt_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

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
  if not db.txRef.isNil:
    return err(TxPendingTx)
  if 0 < db.stack.len:
    return err(TxStackGarbled)

  let be = db.backend
  if be.isNil:
    return err(TxBackendNotWritable)

  # Save structural and other table entries
  let txFrame = be.putBegFn()
  be.putKvpFn(txFrame, db.top.delta.sTab.pairs.toSeq)
  ? be.putEndFn txFrame

  # Clean up
  db.top.delta.sTab.clear

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
