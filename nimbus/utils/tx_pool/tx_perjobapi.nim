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
proc pjaInactiveItemsEviction*(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Move transactions older than `xp.lifeTime` to the waste basket.
  discard xp.job(TxJobDataRef(kind: txJobEvictionInactive))


# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
proc pjaAddTxs*(xp: TxPoolRef;
             txs: openArray[Transaction]; local = false; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueue a batch of transactions into the pool if they are valid. If
  ## the senders are not among the locally tracked ones, full pricing
  ## constraints will apply.
  ##
  ## This method is used to add transactions from the p2p network and does not
  ## wait for pool reorganization and internal event propagation.
  discard xp.job(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    toSeq(txs),
      local:  local,
      info:   info)))

# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
proc pjaAddTx*(xp: TxPoolRef; tx: var Transaction; local = false; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueues a single transaction into the pool if it is valid.
  ## This is a convenience wrapper aroundd addTxs.
  discard xp.job(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    @[tx],
      local:  local,
      info:   info)))


# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc pjaRemoteToLocals*(xp: TxPoolRef; signer: EthAddress)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  discard xp.job(TxJobDataRef(
    kind:      txJobMoveRemoteToLocals,
    moveRemoteToLocalsArgs: (
      account: signer)))

# ----------------------------

proc pjaFlushRejects*(xp: TxPoolRef; numItems = int.high)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Flush/delete at most `numItems` oldest items from the waste basket and
  ## return the numbers of deleted and remaining items (a waste basket item
  ## is considered older if it was moved there earlier.)
  discard xp.job(TxJobDataRef(
    kind:       txJobFlushRejects,
    flushRejectsArgs: (
      maxItems: numItems)))

proc pjaItemsApply*(xp: TxPoolRef; apply: TxJobItemApply; local = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Apply argument function `apply` to all items of the `local` or `remote`
  ## bucket.
  discard xp.job(TxJobDataRef(
    kind:     txJobApplyByLocal,
    applyByLocalArgs: (
      local:  local,
      apply:  apply)))

proc pjaItemsApply*(xp: TxPoolRef; apply: TxJobItemApply; status: TxItemStatus)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Apply argument function `apply` to all items of the bucket with label
  ## matching the `status` argument.
  discard xp.job(TxJobDataRef(
    kind:      txJobApplyByStatus,
    applyByStatusArgs: (
      status:  status,
      apply:   apply)))

proc pjaRejectsApply*(xp: TxPoolRef; apply: TxJobItemApply)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Apply argument function `apply` to all rejected items in the waste basket.
  discard xp.job(TxJobDataRef(
    kind:     txJobApplyByRejected,
    applyByRejectedArgs: (
      apply:  apply)))

proc pjaUpdatePending*(xp: TxPoolRef; force = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Update pending bucket
  discard xp.job(TxJobDataRef(
    kind:     txJobUpdatePending,
    updatePendingArgs: (
      force:  force)))

proc pjaUpdateStaged*(xp: TxPoolRef; force = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Update pending bucket
  discard xp.job(TxJobDataRef(
    kind:     txJobUpdateStaged,
    updateStagedArgs: (
      force:  force)))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
