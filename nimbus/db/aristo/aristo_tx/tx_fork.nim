# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Transaction fork helpers
## =====================================
##
{.push raises: [].}

import results, ./tx_frame, ".."/[aristo_desc, aristo_get, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFork*(
    tx: AristoTxRef, # Transaction descriptor
): Result[AristoDbRef, AristoError] =
  ## Clone a transaction into a new DB descriptor accessing the same backend
  ## database (if any) as the argument `db`. The new descriptor is linked to
  ## the transaction parent and is fully functional as a forked instance (see
  ## comments on `aristo_desc.reCentre()` for details.)
  ##
  ## Input situation:
  ## ::
  ##   tx -> db0   with tx is top transaction, tx.level > 0
  ##
  ## Output situation:
  ## ::
  ##   tx  -> db0 \
  ##               >  share the same backend
  ##   tx1 -> db1 /
  ##
  ## where `tx.level > 0`, `db1.level == 1` and `db1` is returned. The
  ## transaction `tx1` can be retrieved via `db1.txTop()`.
  ##
  ## The new DB descriptor will contain a copy of the argument transaction
  ## `tx` as top layer of level 1 (i.e. this is he only transaction.) Rolling
  ## back will end up at the backend layer (incl. backend filter.)
  ##
  ## Use `aristo_desc.forget()` to clean up this descriptor.
  ##
  let db = tx.db

  # Verify `tx` argument
  if db.txRef == tx:
    if db.top.txUid != tx.txUid:
      return err(TxArgStaleTx)
  elif db.stack.len <= tx.level:
    return err(TxArgStaleTx)
  elif db.stack[tx.level].txUid != tx.txUid:
    return err(TxArgStaleTx)

  # Provide new empty stack layer
  let stackLayer = block:
    let rc = db.getTuvBE()
    if rc.isOk:
      LayerRef(vTop: rc.value)
    elif rc.error == GetTuvNotFound:
      LayerRef.init()
    else:
      return err(rc.error)

  # Set up clone associated to `db`
  let txClone = ?db.fork(noToplayer = true, noFilter = false)
  txClone.top = db.layersCc tx.level # Provide tx level 1 stack
  txClone.stack = @[stackLayer] # Zero level stack
  txClone.top.txUid = 1
  txClone.txUidGen = 1

  # Install transaction similar to `tx` on clone
  txClone.txRef = AristoTxRef(db: txClone, txUid: 1, level: 1)

  ok(txClone)

proc txForkTop*(db: AristoDbRef): Result[AristoDbRef, AristoError] =
  ## Variant of `forkTx()` for the top transaction if there is any. Otherwise
  ## the top layer is cloned, and an empty transaction is set up. After
  ## successful fork the returned descriptor has transaction level 1.
  ##
  ## Use `aristo_desc.forget()` to clean up this descriptor.
  ##
  if db.txRef.isNil:
    let txClone = ?db.fork(noToplayer = true, noFilter = false)
    txClone.top = db.layersCc # Is a deep copy

    discard txClone.txFrameBegin()
    return ok(txClone)
    # End if()

  db.txRef.txFork()

proc txForkBase*(db: AristoDbRef): Result[AristoDbRef, AristoError] =
  ## Variant of `forkTx()`, sort of the opposite of `forkTop()`. This is the
  ## equivalent of top layer forking after all tranactions have been rolled
  ## back.
  ##
  ## Use `aristo_desc.forget()` to clean up this descriptor.
  ##
  if db.txRef.isNil:
    return db.txForkTop()

  let txClone = ?db.fork(noToplayer = true, noFilter = false)
  txClone.top = db.layersCc 0

  discard txClone.txFrameBegin()
  ok(txClone)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
