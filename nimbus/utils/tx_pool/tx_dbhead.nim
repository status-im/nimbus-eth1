# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Block Chain Head State
## =======================================
##

import
  ../../chain_config,
  ../../db/[db_chain, accounts_cache],
  ../../forks,
  ./tx_item,
  eth/[common, keys, p2p]

{.push raises: [Defect].}

type
  TxDbHeadNonce* =
    proc(rdb: ReadOnlyStateDB; account: EthAddress): AccountNonce
      {.gcsafe,raises: [Defect,CatchableError].}

  TxDbHeadBalance* =
    proc(rdb: ReadOnlyStateDB; account: EthAddress): UInt256
      {.gcsafe,raises: [Defect,CatchableError].}

  TxDbHeadRef* = ref object ##\
    ## Cache the state of the block chain which serves as logical insertion
    ## point for a new block. This state is typically the canonical head
    ## when updated.
    db: BaseChainDB            ## Block chain database
    header: BlockHeader        ## New block insertion point
    fork: Fork                 ## Current fork relative to next header
    baseFee: GasPrice          ## Current base fee derived from `header`
    trgGasLimit: GasInt        ## The `gasLimit` for the packer, soft limit
    maxGasLimit: GasInt        ## May increase the `gasLimit` a bit, hard limit
    accDB: AccountsCache       ## Sender accounts, etc.
    nonceFn: TxDbHeadNonce     ## Sender account `getNonce()` function
    balanceFn: TxDbHeadBalance ## Sender account `getBalance()` function

const
  # currently implemented in Nimbus only to do some tesing
  londonBlock = 12_965_000.u256

# ------------------------------------------------------------------------------
# Private functions, account helpers
# ------------------------------------------------------------------------------

proc getBalance(rdb: ReadOnlyStateDB; account: EthAddress): UInt256 =
  ## Wrapper around `getBalance()`
  accounts_cache.getBalance(rdb,account)

proc getNonce(rdb: ReadOnlyStateDB; account: EthAddress): AccountNonce =
  ## Wrapper around `getNonce()`
  accounts_cache.getNonce(rdb,account)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc toForkOrLondon(db: BaseChainDB; number: BlockNumber): Fork =
  ## returns the real fork, including *London* which is unsupported by the
  ## current implementation of configutation tools (does not provide for
  ## detecting a *London* fork unless set manually for debugging.)
  ##
  ## This function also returns *London* on a block earlier than `londonBlock`
  ## if configured smaller than that (as mentioned above, when set manually
  ## for testing.)
  if db.networkId == MainNet and londonBlock <= number:
    return FkLondon
  db.config.toFork(number)


proc update*(dh: TxDbHeadRef; newHead: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Update by new block header
  dh.header = newHead
  dh.fork = dh.db.toForkOrLondon(dh.header.blockNumber + 1)
  dh.accDB = AccountsCache.init(dh.db.db, dh.header.stateRoot, dh.db.pruneTrie)

  if FkLondon <= dh.fork:
    dh.baseFee = dh.header.baseFee.truncate(uint64).GasPrice
    # https://ethereum.org/en/developers/docs/blocks/#block-size
    dh.trgGasLimit = 15_000_000_000.GasInt
    dh.trgGasLimit = 2 * dh.trgGasLimit
  else:
    dh.baseFee = 0.GasPrice
    dh.trgGasLimit = dh.header.gasLimit.GasInt

    # https://ethereum.stackexchange.com/questions/592/
    #           /why-was-frontiers-default-gaslimit-3141592/1092#1092
    # block can increase by sort of 1 promille
    dh.maxGasLimit = dh.trgGasLimit + (dh.trgGasLimit shr 10)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxDbHeadRef; db: BaseChainDB): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor
  new result
  result.db = db
  result.update(db.getCanonicalHead)
  result.nonceFn = getNonce
  result.balanceFn = getBalance

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc accountBalance*(dh: TxDbHeadRef; account: EthAddress): UInt256
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getBalance()`
  dh.balanceFn(ReadOnlyStateDB(dh.accDb),account)

proc accountNonce*(dh: TxDbHeadRef; account: EthAddress): AccountNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getNonce()`
  dh.nonceFn(ReadOnlyStateDB(dh.accDb),account)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc db*(dh: TxDbHeadRef): BaseChainDB =
  ## Getter
  dh.db

proc header*(dh: TxDbHeadRef): BlockHeader =
  ## Getter
  dh.header

proc fork*(dh: TxDbHeadRef): Fork =
  ## Getter
  dh.fork

proc baseFee*(dh: TxDbHeadRef): GasPrice =
  ## Getter
  dh.baseFee

proc trgGasLimit*(dh: TxDbHeadRef): GasInt =
  ## Getter
  dh.trgGasLimit

proc maxGasLimit*(dh: TxDbHeadRef): GasInt =
  ## Getter
  dh.maxGasLimit

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `header=`*(dh: TxDbHeadRef; header: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, updates descriptor
  dh.update(header)

# ------------------------------------------------------------------------------
# Public functions, debugging & testing
# ------------------------------------------------------------------------------

proc setBaseFee*(dh: TxDbHeadRef; val: GasPrice) =
  ## Temorarily overwrite (until next header update). This function
  ## is intended to support debugging and testing.
  dh.baseFee = val

proc setAccountFns*(dh: TxDbHeadRef;
                    nonceFn: TxDbHeadNonce = getNonce;
                    balanceFn: TxDbHeadBalance = getBalance) =
  ## Replace per sender account lookup functions. This function
  ## is intended to support debugging and testing.
  dh.nonceFn = nonceFn
  dh.balanceFn = balanceFn

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
