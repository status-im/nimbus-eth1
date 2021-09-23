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
proc inactiveItemsEviction*(xp: var TxPool): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Remove transactions older than `xp.lifeTime` and theturns the number
  ## of deleted items.
  var nResult: int
  xp.jobCommit(TxJobDataRef(
    kind:    txJobEvictionInactive,
    evictionInactiveArgs: (
      reply: proc(deleted: int) =
               nResult = deleted)))
  nResult

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
proc setGasPrice*(xp: var TxPool; price: GasInt): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set the minimum price required by the transaction pool for a new
  ## transaction. Increasing it will drop all transactions below this
  ## threshold.
  var nResult: int
  xp.jobCommit(TxJobDataRef(
    kind:    txJobSetGasPrice,
    setGasPriceArgs: (
      price: price,
      reply: proc(deleted: int) =
               nResult = deleted)))
  nResult

# core/tx_pool.go(474): func (pool SetGasPrice,*TxPool) Stats() (int, int) {
proc statsReport*(xp: var TxPool): (int,int)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the current pool stats, namely the pair `(#pending,#queued)`,
  ## the number of pending and the number of queued (non-executable)
  ## transactions.
  var nResult: (int,int)
  xp.jobCommit(TxJobDataRef(
    kind:    txJobStatsReport,
    statsReportArgs: (
      reply: proc(pending, queued: int) =
               nResult[0] = pending
               nResult[1] = queued)))
  nResult

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
proc addLocals*(xp: var TxPool;
          txs: var openArray[Transaction]; status = txItemQueued; info = ""):
            Result[void,seq[TxPoolError]]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueues a batch of transactions into the pool if they are valid,
  ## marking the senders as local ones, ensuring they go around the local
  ## pricing constraints.
  ##
  ## This method is used to add transactions from the RPC API and performs
  ## synchronous pool reorganization and event propagation.
  var
    txOk: bool
    errInfo: seq[TxPoolError]
  xp.jobCommit(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    toSeq(txs),
      local:  true,
      status: status,
      info:   info,
      reply:  proc(ok: bool; errors: seq[TxPoolError]) =
                txOk = ok
                errInfo = errors)))
  if txOk:
    return ok()
  err(errInfo)

# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
proc addLocal*(xp: var TxPool;
          tx: var Transaction; status = txItemQueued; info = ""):
            Result[void,TxPoolError]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## AddLocal enqueues a single local transaction into the pool if it is valid.
  ## This is a convenience wrapper aroundd AddLocals.
  var txs = [tx]
  let rc = xp.addLocals(txs, status, info)
  if rc.isErr:
     return err(rc.error[0])
  ok()

# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
proc addRemotes*(xp: var TxPool;
          txs: var openArray[Transaction]; status = txItemQueued; info = ""):
            Result[void,seq[TxPoolError]]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueue a batch of transactions into the pool if they are valid. If
  ## the senders are not among the locally tracked ones, full pricing
  ## constraints will apply.
  ##
  ## This method is used to add transactions from the p2p network and does not
  ## wait for pool reorganization and internal event propagation.
  var
    txOk: bool
    errInfo: seq[TxPoolError]
  xp.jobCommit(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    toSeq(txs),
      local:  false,
      status: status,
      info:   info,
      reply:  proc(ok: bool; errors: seq[TxPoolError]) =
                txOk = ok
                errInfo = errors)))
  if txOk:
    return ok()
  err(errInfo)

# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
proc addRemote*(xp: var TxPool;
          tx: var Transaction; status = txItemQueued; info = ""):
            Result[void,TxPoolError]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueues a single transaction into the pool if it is valid.
  ## This is a convenience wrapper around AddRemotes.
  ##
  ## Deprecated: use AddRemotes
  var txs = [tx]
  let rc = xp.addRemotes(txs, status, info)
  if rc.isErr:
     return err(rc.error[0])
  ok()

# core/tx_pool.go(979): func (pool *TxPool) Get(hash common.Hash) ..
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

# core/tx_pool.go(985): func (pool *TxPool) Has(hash common.Hash) bool {
proc has*(xp: var TxPool; hash: Hash256): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Indicator whether `TxPool` has a transaction cached with the given hash.
  xp.get(hash).isOK

# core/tx_pool.go(1728): func (t *txLookup) Count() int {
proc count*(xp: var TxPool): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## The current number of transactions
  var nLocal, nRemote: int
  xp.jobCommit(TxJobDataRef(
    kind:    txJobLocusCount,
    locusCountArgs: (
      reply: proc(local, remote: int) =
               nLocal = local
               nRemote = remote)))
  nLocal + nRemote

# core/tx_pool.go(1737): func (t *txLookup) LocalCount() int {
proc localCount*(xp: var TxPool): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## The current number of local transactions
  var nLocal: int
  xp.jobCommit(TxJobDataRef(
    kind:    txJobLocusCount,
    locusCountArgs: (
      reply: proc(local, remote: int) =
               nLocal = local)))
  nLocal

# core/tx_pool.go(1745): func (t *txLookup) RemoteCount() int {
proc remoteCount*(xp: var TxPool): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## The current number of remote transactions
  var nRemote: int
  xp.jobCommit(TxJobDataRef(
    kind:    txJobLocusCount,
    locusCountArgs: (
      reply: proc(local, remote: int) =
               nRemote = remote)))
  nRemote

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
