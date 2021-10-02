# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool, Per-Job API For Testing
## =========================================

import
  std/[sequtils],
  ../tx_pool,
  ./tx_info,
  ./tx_job,
  eth/[common, keys],
  stew/results

# ------------------------------------------------------------------------------
# Public functions, per-job API -- temporary for testing
# ------------------------------------------------------------------------------

# core/tx_pool.go(384): for addr := range pool.queue {
proc inactiveItemsEviction*(xp: var TxPool)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Move transactions older than `xp.lifeTime` to the waste basket.
  xp.jobCommit(TxJobDataRef(kind: txJobEvictionInactive))

proc setBaseFee*(xp: var TxPool; baseFee: uint64)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, implies re-org
  xp.jobCommit(TxJobDataRef(
    kind:     txJobSetBaseFee,
    setBaseFeeArgs: (
      price:  baseFee)))

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setGasPrice*(xp: var TxPool; price: uint64)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set the minimum price required by the transaction pool for a new
  ## transaction. Increasing it will move all transactions below this
  ## threshold to the waste basket.
  xp.jobCommit(TxJobDataRef(
    kind:     txJobSetGasPrice,
    setGasPriceArgs: (
      price:  price)))


# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
proc addTxs*(xp: var TxPool;
             txs: openArray[Transaction]; local = false; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueue a batch of transactions into the pool if they are valid. If
  ## the senders are not among the locally tracked ones, full pricing
  ## constraints will apply.
  ##
  ## This method is used to add transactions from the p2p network and does not
  ## wait for pool reorganization and internal event propagation.
  xp.jobCommit(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    toSeq(txs),
      local:  local,
      info:   info)))

# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
proc addTx*(xp: var TxPool; tx: var Transaction; local = false; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueues a single transaction into the pool if it is valid.
  ## This is a convenience wrapper aroundd addTxs.
  xp.addTxs([tx], local, info)


# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc remoteToLocals*(xp: var TxPool; signer: EthAddress)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  xp.jobCommit(TxJobDataRef(
    kind:      txJobMoveRemoteToLocals,
    moveRemoteToLocalsArgs: (
      account: signer)))

# ----------------------------

proc flushRejects*(xp: var TxPool; numItems = int.high)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Flush/delete at most `numItems` oldest items from the waste basket and
  ## return the numbers of deleted and remaining items (a waste basket item
  ## is considered older if it was moved there earlier.)
  xp.jobCommit(TxJobDataRef(
    kind:       txJobFlushRejects,
    flushRejectsArgs: (
      maxItems: numItems)))

proc itemsApply*(xp: var TxPool; apply: TxJobItemApply; local = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Apply argument function `apply` to all items of the `local` or `remote`
  ## queue.
  xp.jobCommit(TxJobDataRef(
    kind:     txJobApplyByLocal,
    applyByLocalArgs: (
      local:  local,
      apply:  apply)))

proc itemsApply*(xp: var TxPool; apply: TxJobItemApply; status: TxItemStatus)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Apply argument function `apply` to all items of the `status` queue.
  xp.jobCommit(TxJobDataRef(
    kind:      txJobApplyByStatus,
    applyByStatusArgs: (
      status:  status,
      apply:   apply)))

proc rejectsApply*(xp: var TxPool; apply: TxJobItemApply)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Apply argument function `apply` to all rejected items in the waste basket.
  xp.jobCommit(TxJobDataRef(
    kind:     txJobApplyByRejected,
    applyByRejectedArgs: (
      apply:  apply)))

proc rejectItem*(xp: var TxPool; item: TxItemRef; reason: TxInfo)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Move item to wastebasket
  ##
  ## :CAVEAT:
  ##   This function must not be used inside a call back function as of
  ##   `itemsApply()`. Add the job directly using the `job()` function.
  xp.jobCommit(TxJobDataRef(
    kind:      txJobRejectItem,
    rejectItemArgs: (
      item:    item,
      reason:  reason)))

proc setStatus*(xp: var TxPool; item: TxItemRef; status: TxItemStatus)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Change/update the status of the transaction item.
  xp.jobCommit(TxJobDataRef(
    kind:      txJobItemSetStatus,
    itemSetStatusArgs: (
      item:    item,
      status:  status)))

proc updatePending*(xp: var TxPool; force = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Update pending queue
  xp.jobCommit(TxJobDataRef(
    kind:     txJobUpdatePending,
    updatePendingArgs: (
      force:  force)))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
