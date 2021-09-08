# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool
## ================

import
  std/[tables, times],
   ./keequ,
  ./tx_pool/[tx_base, tx_item, tx_jobs],
  eth/[common, keys],
  stew/results

export
  TxItemRef,
  results,
  tx_item.id,
  tx_item.info,
  tx_item.local,
  tx_item.timeStamp,
  tx_item.tx,
  tx_jobs.TxJobData,
  tx_jobs.TxJobID,
  tx_jobs.TxJobKind,
  tx_jobs.TxJobPair

const
  txPoolLifeTime = initDuration(hours = 3)
  # Journal:   "transactions.rlp",
  # Rejournal: time.Hour,
  #
  # PriceLimit: 1,
  # PriceBump:  10,
  #
  # AccountSlots: 16,
  # GlobalSlots:  4096 + 1024, // urgent + floating queue capacity with
  #                            // 4:1 ratio
  # AccountQueue: 64,
  # GlobalQueue:  1024,

type
  TxPool* = object of TxPoolBase ##\
    ## Transaction pool descriptor
    startDate: Time     ## Start date (read-only)
    lifeTime*: Duration ## Maximum amount of time non-executable

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc utcNow: Time =
  now().utc.toTime

proc pp(t: Time): string =
  t.format("yyyy-MM-dd'T'HH:mm:ss'.'fff", utc())

# ------------------------------------------------------------------------------
# Private run handlers
# ------------------------------------------------------------------------------

proc inactiveJobsEviction(xp: var TxPool; maxLifeTime: Duration)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Any non-local transaction old enough will be removed
  let deadLine = utcNow() - maxLifeTime
  #echo "*** item",
  #    " ttl=", maxLifeTime.inMilliSeconds, "ms",
  #    " ttd=", deadLine.pp, " now=", utcNow().pp,
  #    " remote=#", xp.byRemoteQueueLen
  for item in xp.firstOutItems(local = false):
    if deadLine < item.timeStamp:
      break
    discard xp.delete(item.id)
    #if item.timeStamp <= deadLine:
    #  echo "--- item info=", item.info, " time=", item.timeStamp.pp
    #  discard xp.delete(item.id)
    #else:
    #  echo "+++ item info=", item.info, " time=", item.timeStamp.pp

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

method init*(xp: var TxPool) =
  ## Constructor, returns new tx-pool descriptor.
  procCall xp.TxPoolBase.init
  xp.startDate = utcNow()
  xp.lifeTime = txPoolLifeTime

proc initTxPool*: TxPool =
  ## Ditto
  result.init

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc startDate*(xp: var TxPool): auto {.inline.} =
  ## Getter
  xp.startDate

# ------------------------------------------------------------------------------
# GO tx_pool todo list
# ------------------------------------------------------------------------------

# ErrAlreadyKnown is returned if the transactions is already contained
# within the pool.
#ErrAlreadyKnown = errors.New("already known")

# ErrInvalidSender is returned if the transaction contains an invalid signature.
#ErrInvalidSender = errors.New("invalid sender")

# ErrUnderpriced is returned if a transaction's gas price is below the minimum
# configured for the transaction pool.
#ErrUnderpriced = errors.New("transaction underpriced")

# ErrTxPoolOverflow is returned if the transaction pool is full and can't accpet
# another remote transaction.
#ErrTxPoolOverflow = errors.New("txpool is full")

# ErrReplaceUnderpriced is returned if a transaction is attempted to be replaced
# with a different one without the required price bump.
#ErrReplaceUnderpriced = errors.New("replacement transaction underpriced")

# ErrGasLimit is returned if a transaction's requested gas limit exceeds the
# maximum allowance of the current block.
#ErrGasLimit = errors.New("exceeds block gas limit")

# ErrNegativeValue is a sanity error to ensure no one is able to specify a
## transaction with a negative value.
#ErrNegativeValue = errors.New("negative value")

# ErrOversizedData is returned if the input data of a transaction is greater
# than some meaningful limit a user might use. This is not a consensus error
# making the transaction invalid, rather a DOS protection.
#ErrOversizedData = errors.New("oversized data")

# TxStatus is the current status of a transaction as seen by the pool.
#type TxStatus uint

#const (
#       TxStatusUnknown TxStatus = iota
#       TxStatusQueued
#       TxStatusPending
#       TxStatusIncluded)

# TxPoolConfig are the configuration parameters of the transaction pool.
#type TxPoolConfig struct {
#   Locals    []common.Address // Addresses that should be treated by default
#                              // as local
#   NoLocals  bool             // Whether local transaction handling should be
#                              // disabled
#   Journal   string           // Journal of local transactions to survive node
#                              // restarts
#   Rejournal time.Duration    // Time interval to regenerate the local
#                              // transaction journal
#
#   PriceLimit uint64   // Minimum gas price to enforce for acceptance into the
#                       // pool
#   PriceBump  uint64   // Minimum price bump percentage to replace an already
#                       // existing transaction (nonce)
#
#   AccountSlots uint64 // Number of executable transaction slots guaranteed
#                       // per account
#   GlobalSlots  uint64 // Maximum number of executable transaction slots for
#                       // all accounts
#   AccountQueue uint64 // Maximum number of non-executable transaction slots
#                       // permitted per account
#   GlobalQueue  uint64 // Maximum number of non-executable transaction slots
#                       // for all accounts
#
#   Lifetime time.Duration) // Maximum amount of time non-executable
#                           // transaction are queued

# DefaultTxPoolConfig contains the default configurations for the transaction
# pool.

# sanitize checks the provided user configurations and changes anything that's
# unreasonable or unworkable.
#func (config *TxPoolConfig) sanitize() TxPoolConfig

# TxPool contains all currently known transactions. Transactions
# enter the pool when they are received from the network or submitted
# locally. They exit the pool when they are included in the blockchain.
#
# The pool separates processable transactions (which can be applied to the
# current state) and future transactions. Transactions move between those
# two states over time as they are received and processed.
#type TxPool struct

# NewTxPool creates a new transaction pool to gather, sort and filter inbound
# transactions from the network.
#func NewTxPool(
#  config TxPoolConfig, chainconfig *params.ChainConfig, chain blockChain)
#    *TxPool

# Stop terminates the transaction pool.
#func (pool *TxPool) Stop()

# SubscribeNewTxsEvent registers a subscription of NewTxsEvent and
# starts sending event to the given channel.
#func (pool *TxPool) SubscribeNewTxsEvent(ch chan<- NewTxsEvent)
#  event.Subscription

# GasPrice returns the current gas price enforced by the transaction pool.
#func (pool *TxPool) GasPrice() *big.Int

# SetGasPrice updates the minimum price required by the transaction pool for a
# new transaction, and drops all transactions below this threshold.
#func (pool *TxPool) SetGasPrice(price *big.Int)

# Nonce returns the next nonce of an account, with all transactions executable
# by the pool already applied on top.
#func (pool *TxPool) Nonce(addr common.Address) uint64

# Stats retrieves the current pool stats, namely the number of pending and the
# number of queued (non-executable) transactions.
#func (pool *TxPool) Stats() (int, int)

# Content retrieves the data content of the transaction pool, returning all the
# pending as well as queued transactions, grouped by account and sorted by
# nonce.
#func (pool *TxPool) Content()
#  (map[common.Address]types.Transactions,
#   map[common.Address]types.Transactions)

# ContentFrom retrieves the data content of the transaction pool, returning the
# pending as well as queued transactions of this address, grouped by nonce.
#func (pool *TxPool) ContentFrom(addr common.Address)
#  (types.Transactions, types.Transactions)

# Pending retrieves all currently processable transactions, grouped by origin
# account and sorted by nonce. The returned transaction set is a copy and can
# be freely modified by calling code.
#
# The enforceTips parameter can be used to do an extra filtering on the pending
# transactions and only return those whose **effective** tip is large enough in
# the next pending execution environment.
#func (pool *TxPool) Pending(enforceTips bool)
#  (map[common.Address]types.Transactions, error) {

# Locals retrieves the accounts currently considered local by the pool.
#func (pool *TxPool) Locals() []common.Address

# AddLocals enqueues a batch of transactions into the pool if they are valid,
# marking the senders as a local ones, ensuring they go around the local
# pricing constraints.
#
# This method is used to add transactions from the RPC API and performs
# synchronous pool reorganization and event propagation.
#func (pool *TxPool) AddLocals(txs []*types.Transaction) []error

# AddLocal enqueues a single local transaction into the pool if it is valid.
# This is a convenience wrapper aroundd AddLocals.
# func (pool *TxPool) AddLocal(tx *types.Transaction) error

# AddRemotes enqueues a batch of transactions into the pool if they are valid.
# If the senders are not among the locally tracked ones, full pricing
# constraints will apply.
#
# This method is used to add transactions from the p2p network and does not
# wait for pool reorganization and internal event propagation.
# func (pool *TxPool) AddRemotes(txs []*types.Transaction) []error

# This is like AddRemotes, but waits for pool reorganization. Tests use this
# method.
#func (pool *TxPool) AddRemotesSync(txs []*types.Transaction) []error

# AddRemote enqueues a single transaction into the pool if it is valid. This
# is a convenience wrapper around AddRemotes.
#
# Deprecated: use AddRemotes
#func (pool *TxPool) AddRemote(tx *types.Transaction) error

# Status returns the status (unknown/pending/queued) of a batch of transactions
# identified by their hashes.
#func (pool *TxPool) Status(hashes []common.Hash) []TxStatus

# Get returns a transaction if it is contained in the pool and nil otherwise.
#func (pool *TxPool) Get(hash common.Hash) *types.Transaction

# Has returns an indicator whether txpool has a transaction cached with the
# given hash.
#func (pool *TxPool) Has(hash common.Hash) bool

# Range calls f on each key and value present in the map. The callback passed
# should return the indicator whether the iteration needs to be continued.
# Callers need to specify which set (or both) to be iterated.
#func (t *txLookup) Range(
#  f func(hash common.Hash, tx *types.Transaction, local bool)
#     bool, local bool, remote bool)

# Get returns a transaction if it exists in the lookup, or nil if not found.
#func (t *txLookup) Get(hash common.Hash) *types.Transaction

# GetLocal returns a transaction if it exists in the lookup, or nil if not
# found.
#func (t *txLookup) GetLocal(hash common.Hash) *types.Transaction

# GetRemote returns a transaction if it exists in the lookup, or nil if not
# found.
# func (t *txLookup) GetRemote(hash common.Hash) *types.Transaction

# Count returns the current number of transactions in the lookup.
#func (t *txLookup) Count() int

# LocalCount returns the current number of local transactions in the lookup.
#func (t *txLookup) LocalCount() int

# RemoteCount returns the current number of remote transactions in the lookup.
#func (t *txLookup) RemoteCount() int

# Slots returns the current number of slots used in the lookup.
#func (t *txLookup) Slots() int

# Add adds a transaction to the lookup.
#func (t *txLookup) Add(tx *types.Transaction, local bool)

# Remove removes a transaction from the lookup.
#func (t *txLookup) Remove(hash common.Hash)

# RemoteToLocals migrates the transactions belongs to the given locals to locals
# set. The assumption is held the locals set is thread-safe to be used.
#func (t *txLookup) RemoteToLocals(locals *accountSet) int

# ------------------------------------------------------------------------------
# Public functions, go like API
# ------------------------------------------------------------------------------

# core/tx_pool.go(1813): func (t *txLookup) RemotesBelowTip(threshold ..
proc remotesBelowTip(xp: var TxPool; threshold: GasInt): seq[Hash256]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Finds all remote transactions below the given tip threshold (effective
  ## only with *EIP-1559* support, otherwise all transactions are returned.)
  for _,itList in xp.byGasTipCapDecMPairs(fromLe = threshold):
    for item in itList.nextKeys:
      if not item.local:
        result.add item.id

# ------------------------------------------------------------------------------
# Public functions, other
# ------------------------------------------------------------------------------

proc commit*(xp: var TxPool): int {.gcsafe,raises: [Defect,KeyError].} =
  ## Executes the jobs in the queue (if any.) The function returns the
  ## number of executes jobs.
  var rc = xp.byJobsShift
  while rc.isOK:
    let job: TxJobPair = rc.value
    rc = xp.byJobsShift

    var header: BlockHeader
    case job.data.kind
    of txJobNone:
      echo "here"
    of txJobsInactiveJobsEviction:
      xp.inactiveJobsEviction(xp.lifeTime)
      result.inc
    else:
      discard

proc isJobOk*(id: TxJobID): bool =
  ## The function returns `true` if the argument job `id` is valid.
  id != 0.TxJobID and id <= TxJobIdMax

proc job*(xp: var TxPool; job: TxJobData): TxJobID
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Append a new job to the queue.
  xp.byJobs.txAdd(job)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
