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

proc setBaseFee*(xp: var TxPool; baseFee: GasInt)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, new base fee (implies reorg). The argument value `TxNoBaseFee`
  ## disables the `baseFee`.
  xp.jobCommit(TxJobDataRef(
    kind:      txJobSetBaseFee,
    setBaseFeeArgs: (
      disable: baseFee == TxNoBaseFee,
      price:   baseFee)))

proc getBaseFee*(xp: var TxPool): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Get the `baseFee` implying the price list valuation and order. If
  ## this entry in disabled, the value `TxNoBaseFee` is returnded.
  var rBaseFee: GasInt
  xp.jobCommit(TxJobDataRef(
    kind: txJobGetBaseFee,
    getBaseFeeArgs: (
      reply: proc(baseFee: GasInt) =
               rBaseFee = baseFee)))
  rBaseFee

# core/tx_pool.go(435): func (pool *TxPool) GasPrice() *big.Int {
proc getGasPrice*(xp: var TxPool): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Get the current gas price enforced by the transaction pool.
  var rGasPrice: GasInt
  xp.jobCommit(TxJobDataRef(
    kind:    txJobGetGasPrice,
    getGasPriceArgs: (
      reply: proc(gasPrice: GasInt) =
               rGasPrice = gasPrice)))
  rGasPrice

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setGasPrice*(xp: var TxPool; price: GasInt)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set the minimum price required by the transaction pool for a new
  ## transaction. Increasing it will move all transactions below this
  ## threshold to the waste basket.
  xp.jobCommit(TxJobDataRef(
    kind:     txJobSetGasPrice,
    setGasPriceArgs: (
      price:  price)))

# core/tx_pool.go(474): func (pool SetGasPrice,*TxPool) Stats() (int, int) {
# core/tx_pool.go(1728): func (t *txLookup) Count() int {
# core/tx_pool.go(1737): func (t *txLookup) LocalCount() int {
# core/tx_pool.go(1745): func (t *txLookup) RemoteCount() int {
proc count*(xp: var TxPool): TxTabsStatsCount
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## The current number of local transactions
  var rStatus: TxTabsStatsCount
  xp.jobCommit(TxJobDataRef(
    kind:    txJobStatsCount,
    statsCountArgs: (
      reply: proc(status: TxTabsStatsCount) =
               rStatus = status)))
  rStatus


# core/tx_pool.go(561): func (pool *TxPool) Locals() []common.Address {
proc localAccounts*(xp: var TxPool): seq[EthAddress]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the accounts currently considered local by the pool.
  var rAccounts: seq[EthAddress]
  xp.jobCommit(TxJobDataRef(
    kind:    txJobGetAccounts,
    getAccountsArgs: (
      local: true,
      reply: proc(accounts: seq[EthAddress]) =
               rAccounts = accounts)))
  rAccounts


# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
proc addTxs*(xp: var TxPool; txs: openArray[Transaction]; local = false;
             status = txItemQueued; info = "")
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
      status: status,
      info:   info)))

# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
proc addTx*(xp: var TxPool; tx: var Transaction; local = false;
            status = txItemQueued; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueues a single transaction into the pool if it is valid.
  ## This is a convenience wrapper aroundd addTxs.
  xp.addTxs([tx], local, status, info)

# core/tx_pool.go(979): func (pool *TxPool) Get(hash common.Hash) ..
# core/tx_pool.go(985): func (pool *TxPool) Has(hash common.Hash) bool {
proc get*(xp: var TxPool; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Returns a transaction if it is contained in the pool.
  var getItem: TxItemRef
  xp.jobCommit(TxJobDataRef(
    kind:     txJobGetItem,
    getItemArgs: (
      itemId: hash,
      reply:  proc(item: TxItemRef) =
                getItem = item)))
  if getItem.isNil:
    return err()
  ok(getItem)


# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc remoteToLocals*(xp: var TxPool; signer: EthAddress): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  var nMoved: int
  xp.jobCommit(TxJobDataRef(
    kind:    txJobMoveRemoteToLocals,
    moveRemoteToLocalsArgs: (
      account: signer,
      reply:   proc(moved: int) =
                 nMoved = moved)))
  nMoved

# ----------------------------

proc flushRejects*(xp: var TxPool; numItems = int.high): (int,int)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Flush/delete at most `numItems` oldest items from the waste basket and
  ## return the numbers of deleted and remaining items (a waste basket item
  ## is considered older if it was moved there earlier.)
  var nDeleted, nRemaining: int
  xp.jobCommit(TxJobDataRef(
    kind:       txJobFlushRejects,
    flushRejectsArgs: (
      maxItems: numItems,
      reply:    proc(deteted, remaining: int) =
                  nDeleted = deteted
                  nRemaining = remaining)))
  (nDeleted, nRemaining)

proc setMaxRejects*(xp: var TxPool; size: int)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set the size of the waste basket. This setting becomes effective with
  ## the next move of an item into the waste basket.
  xp.jobCommit(TxJobDataRef(
    kind:    txJobSetMaxRejects,
    setMaxRejectsArgs: (
      size:  size)))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
