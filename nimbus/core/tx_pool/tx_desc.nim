# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Descriptor
## ===========================
##

import
  std/[times],
  eth/eip1559,
  ../../common/common,
  ../../evm/state,
  ../../evm/types,
  ../../db/ledger,
  ../../constants,
  ../../core/chain/forked_chain,
  ../pow/header,
  ../eip4844,
  ../casper,
  ./tx_item,
  ./tx_tabs,
  ./tx_tabs/tx_sender

{.push raises: [].}

type
  TxPoolFlags* = enum ##\
    ## Processing strategy selector symbols

    autoUpdateBucketsDB ##\
      ## Automatically update the state buckets after running batch jobs if
      ## the `dirtyBuckets` flag is also set.

    autoZombifyUnpacked ##\
      ## Automatically dispose *pending* or *staged* txs that were queued
      ## at least `lifeTime` ago.

  TxPoolParam* = tuple          ## Getter/setter accessible parameters
    dirtyBuckets: bool          ## Buckets need to be updated
    doubleCheck: seq[TxItemRef] ## Check items after moving block chain head
    flags: set[TxPoolFlags]     ## Processing strategy symbols

  TxPoolRef* = ref object of RootObj ##\
    ## Transaction pool descriptor
    startDate: Time             ## Start date (read-only)
    param: TxPoolParam          ## Getter/Setter parameters

    vmState: BaseVMState
    txDB: TxTabsRef             ## Transaction lists & tables

    lifeTime*: times.Duration   ## Maximum life time of a tx in the system
    priceBump*: uint            ## Min precentage price when superseding
    chain*: ForkedChainRef

const
  txItemLifeTime = ##\
    ## Maximum amount of time transactions can be held in the database\
    ## unless they are packed already for a block. This default is chosen\
    ## as found in core/tx_pool.go(184) of the geth implementation.
    initDuration(hours = 3)

  txPriceBump = ##\
    ## Minimum price bump percentage to replace an already existing\
    ## transaction (nonce). This default is chosen as found in\
    ## core/tx_pool.go(177) of the geth implementation.
    10u

  txPoolFlags = {autoUpdateBucketsDB,
                  autoZombifyUnpacked}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc baseFeeGet(com: CommonRef; parent: Header): Opt[UInt256] =
  ## Calculates the `baseFee` of the head assuming this is the parent of a
  ## new block header to generate.

  # Note that the baseFee is calculated for the next header
  if not com.isLondonOrLater(parent.number+1):
    return Opt.none(UInt256)

  # If the new block is the first EIP-1559 block, return initial base fee.
  if not com.isLondonOrLater(parent.number):
    return Opt.some(EIP1559_INITIAL_BASE_FEE)

  Opt.some calcEip1599BaseFee(
    parent.gasLimit,
    parent.gasUsed,
    parent.baseFeePerGas.get(0.u256))

proc gasLimitsGet(com: CommonRef; parent: Header): GasInt =
  if com.isLondonOrLater(parent.number+1):
    var parentGasLimit = parent.gasLimit
    if not com.isLondonOrLater(parent.number):
      # Bump by 2x
      parentGasLimit = parent.gasLimit * EIP1559_ELASTICITY_MULTIPLIER
    calcGasLimit1559(parentGasLimit, desiredLimit = com.gasLimit)
  else:
    computeGasLimit(
      parent.gasUsed,
      parent.gasLimit,
      gasFloor = com.gasLimit,
      gasCeil = com.gasLimit)

proc setupVMState(com: CommonRef; parent: Header, parentFrame: CoreDbTxRef): BaseVMState =
  # do hardfork transition before
  # BaseVMState querying any hardfork/consensus from CommonRef

  let pos = com.pos

  let blockCtx = BlockContext(
    timestamp    : pos.timestamp,
    gasLimit     : gasLimitsGet(com, parent),
    baseFeePerGas: baseFeeGet(com, parent),
    prevRandao   : pos.prevRandao,
    difficulty   : UInt256.zero(),
    coinbase     : pos.feeRecipient,
    excessBlobGas: calcExcessBlobGas(parent, com.isPragueOrLater(pos.timestamp)),
    parentHash   : parent.blockHash,
  )

  BaseVMState.new(
    parent   = parent,
    blockCtx = blockCtx,
    com      = com,
    txFrame = com.db.ctx.txFrameBegin(parentFrame)
    )

proc update(xp: TxPoolRef; parent: Header) =
  xp.vmState = setupVMState(xp.vmState.com, parent, xp.chain.txFrame(parent))

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: TxPoolRef; chain: ForkedChainRef) =
  ## Constructor, returns new tx-pool descriptor.
  xp.startDate = getTime().utc.toTime

  let head = chain.latestHeader
  xp.vmState = setupVMState(chain.com, head, chain.txFrame(head))
  xp.txDB = TxTabsRef.new

  xp.lifeTime = txItemLifeTime
  xp.priceBump = txPriceBump

  xp.param.reset
  xp.param.flags = txPoolFlags
  xp.chain = chain

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc clearAccounts*(xp: TxPoolRef) =
  ## Reset transaction environment, e.g. before packing a new block
  xp.update(xp.vmState.parent)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func pFlags*(xp: TxPoolRef): set[TxPoolFlags] =
  ## Returns the set of algorithm strategy symbols for labelling items
  ## as`packed`
  xp.param.flags

func pDirtyBuckets*(xp: TxPoolRef): bool =
  ## Getter, buckets need update
  xp.param.dirtyBuckets

func pDoubleCheck*(xp: TxPoolRef): seq[TxItemRef] =
  ## Getter, cached block chain head was moved back
  xp.param.doubleCheck

func startDate*(xp: TxPoolRef): Time =
  ## Getter
  xp.startDate

func txDB*(xp: TxPoolRef): TxTabsRef =
  ## Getter, pool database
  xp.txDB

func baseFee*(xp: TxPoolRef): GasInt =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  if xp.vmState.blockCtx.baseFeePerGas.isSome:
    xp.vmState.blockCtx.baseFeePerGas.get.truncate(GasInt)
  else:
    0.GasInt

func vmState*(xp: TxPoolRef): BaseVMState =
  xp.vmState

func nextFork*(xp: TxPoolRef): EVMFork =
  xp.vmState.fork

func gasLimit*(xp: TxPoolRef): GasInt =
  xp.vmState.blockCtx.gasLimit

func excessBlobGas*(xp: TxPoolRef): GasInt =
  xp.vmState.blockCtx.excessBlobGas

proc getBalance*(xp: TxPoolRef; account: Address): UInt256 =
  ## Wrapper around `vmState.readOnlyStateDB.getBalance()` for a `vmState`
  ## descriptor positioned at the `dh.head`. This might differ from the
  ## `dh.vmState.readOnlyStateDB.getBalance()` which returnes the current
  ## balance relative to what has been accumulated by the current packing
  ## procedure.
  xp.vmState.stateDB.getBalance(account)

proc getNonce*(xp: TxPoolRef; account: Address): AccountNonce =
  ## Wrapper around `vmState.readOnlyStateDB.getNonce()` for a `vmState`
  ## descriptor positioned at the `dh.head`. This might differ from the
  ## `dh.vmState.readOnlyStateDB.getNonce()` which returnes the current balance
  ## relative to what has been accumulated by the current packing procedure.
  xp.vmState.stateDB.getNonce(account)

func head*(xp: TxPoolRef): Header =
  ## Getter, cached block chain insertion point. Typocally, this should be the
  ## the same header as retrieved by the `ForkedChainRef.latestHeader` (unless in the
  ## middle of a mining update.)
  xp.vmState.parent

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

func `pDirtyBuckets=`*(xp: TxPoolRef; val: bool) =
  ## Setter
  xp.param.dirtyBuckets = val

func pDoubleCheckAdd*(xp: TxPoolRef; val: seq[TxItemRef]) =
  ## Pseudo setter
  xp.param.doubleCheck.add val

func pDoubleCheckFlush*(xp: TxPoolRef) =
  ## Pseudo setter
  xp.param.doubleCheck.setLen(0)

func `pFlags=`*(xp: TxPoolRef; val: set[TxPoolFlags]) =
  ## Install a set of algorithm strategy symbols for labelling items as`packed`
  xp.param.flags = val

proc `head=`*(xp: TxPoolRef; val: Header)
    {.gcsafe,raises: [].} =
  ## Setter, updates descriptor. This setter re-positions the `vmState` and
  ## account caches to a new insertion point on the block chain database.
  xp.update(val)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
