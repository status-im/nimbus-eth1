# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Transaction fork helpers
## ==================================
##
{.push raises: [].}

import
  results,
  ./tx_frame,
  ".."/[kvt_desc, kvt_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFork*(tx: KvtTxRef): Result[KvtDbRef,KvtError] =
  ## Clone a transaction into a new DB descriptor  accessing the same backend
  ## (if any) database as the argument `db`. The new descriptor is linked to
  ## the transaction parent and is fully functional as a forked instance (see
  ## comments on `kvt_desc.reCentre()` for details.)
  ##
  ## The new DB descriptor will contain a copy of the argument transaction
  ## `tx` as top layer of level 1 (i.e. this is he only transaction.) Rolling
  ## back will end up at the backend layer (incl. backend filter.)
  ##
  ## Use `kvt_desc.forget()` to clean up this descriptor.
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

  # Set up clone associated to `db`
  let txClone = ? db.fork()
  txClone.top = db.layersCc tx.level
  txClone.stack = @[LayerRef()]          # Provide tx level 1 stack
  txClone.top.txUid = 1
  txClone.txUidGen = 1                   # Used value of `txClone.top.txUid`

  # Install transaction similar to `tx` on clone
  txClone.txRef = KvtTxRef(
    db:    txClone,
    txUid: 1,
    level: 1)

  ok(txClone)


proc txForkTop*(db: KvtDbRef): Result[KvtDbRef,KvtError] =
  ## Variant of `forkTx()` for the top transaction if there is any. Otherwise
  ## the top layer is cloned, and an empty transaction is set up. After
  ## successful fork the returned descriptor has transaction level 1.
  ##
  ## Use `kvt_desc.forget()` to clean up this descriptor.
  ##
  if db.txRef.isNil:
    let dbClone = ? db.fork()
    dbClone.top = db.layersCc()

    discard dbClone.txFrameBegin()
    return ok(dbClone)

  db.txRef.txFork


proc txForkBase*(
    db: KvtDbRef;
      ): Result[KvtDbRef,KvtError] =
  if db.txRef.isNil:
    return db.txForkTop()

  let txClone = ? db.fork()
  txClone.top = db.layersCc 0

  discard txClone.txFrameBegin()
  ok(txClone)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
