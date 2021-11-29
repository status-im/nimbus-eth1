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
  std/[times],
  ../../chain_config,
  ../../constants,
  ../../db/[db_chain, accounts_cache],
  ../../forks,
  ../../p2p/executor,
  ../../utils,
  ../../vm_state,
  ../../vm_types,
  ../difficulty,
  ./tx_chain/[tx_basefee, tx_gaslimits],
  ./tx_item,
  eth/[common],
  nimcrypto

export
  TxChainGasLimits

{.push raises: [Defect].}

type
  TxChainError* = object of CatchableError
    ## Catch and relay exception error

  TxChainNextHeader = tuple
    baseFee: GasPrice        ## Base fee derived from `head`
    receipts: seq[Receipt]   ## `vmState.receipts` after packing
    reward: GasPriceEx       ## Miner balance difference after packing
    txRoot: Hash256          ## `rootHash` after packing

  TxChainRef* = ref object ##\
    ## Cache the state of the block chain which serves as logical insertion
    ## point for a new block. This state is typically the canonical head
    ## when updated.
    db: BaseChainDB          ## Block chain database
    miner: EthAddress        ## Address of fee beneficiary

    parent: BlockHeader      ## Current block chain insertion point
    accounts: AccountsCache  ## Accounts cache, depending on insertion point
    limits: TxChainGasLimits ## Gas limits for packer and next header
    child: TxChainNextHeader ## Assorted parameters for the next header

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template safeExecutor(info: string; code: untyped) =
  try:
    code
  except CatchableError as e:
    raise (ref CatchableError)(msg: e.msg)
  except Defect as e:
    raise (ref Defect)(msg: e.msg)
  except:
    let e = getCurrentException()
    raise newException(
      TxChainError, info & "(): " & $e.name & " -- " & e.msg)


proc update(dh: TxChainRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  let db = dh.db
  dh.accounts = AccountsCache.init(db.db, dh.parent.stateRoot, db.pruneTrie)
  dh.limits = db.gasLimitsGet(dh.parent)
  dh.child.reset
  dh.child.baseFee = db.config.baseFeeGet(dh.parent)
  dh.child.txRoot = BLANK_ROOT_HASH

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc new*(T: type TxChainRef; db: BaseChainDB; miner: EthAddress): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor
  new result

  result.db = db
  result.parent = db.getCanonicalHead
  result.miner = miner
  result.update

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getBalance*(dh: TxChainRef; account: EthAddress): UInt256
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getBalance()`
  ReadOnlyStateDB(dh.accounts).getBalance(account)

proc getNonce*(dh: TxChainRef; account: EthAddress): AccountNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getNonce()`
  ReadOnlyStateDB(dh.accounts).getNonce(account)


proc getHeader*(dh: TxChainRef): BlockHeader
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Generate a new header, a child of the cached `head` (similar to
  ## `utils.generateHeaderFromParentHeader()`.)
  let
    config = dh.db.config
    blockNumber = dh.parent.blockNumber + 1
    tStamp = getTime().utc.toTime

    gasUsed = if dh.child.receipts.len == 0: 0.GasInt
              else: dh.child.receipts[^1].cumulativeGasUsed

    gasLimit = if dh.limits.trgLimit < gasUsed:   dh.limits.maxLimit
               elif gasUsed < dh.limits.minLimit: dh.limits.minLimit
               else:                              gasUsed

    feeOption = if FkLondon <= config.toFork(blockNumber):
                  some(dh.child.baseFee.uint64.u256)
                else:
                  UInt256.none()

  BlockHeader(
    parentHash:  dh.parent.blockHash,
    ommersHash:  EMPTY_UNCLE_HASH,
    coinbase:    dh.miner,
    stateRoot:   dh.parent.stateRoot,
    txRoot:      dh.child.txRoot,
    receiptRoot: dh.child.receipts.calcReceiptRoot,
    bloom:       dh.child.receipts.createBloom,
    difficulty:  config.calcDifficulty(tStamp, dh.parent),
    blockNumber: blockNumber,
    gasLimit:    gasLimit,
    gasUsed:     gasUsed,
    timestamp:   tStamp,
    # extraData: Blob       # signing data
    # mixDigest: Hash256    # mining hash for given difficulty
    # nonce:     BlockNonce # mining free vaiable
    fee:         feeOption)


proc getVmState*(dh: TxChainRef; pristine = false): BaseVMState
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Returns a copy of a clean `vmState` based on the current
  ## insertion point.
  safeExecutor "tx_chain.getVmState()":
    result = dh.accounts.newBaseVMState(dh.parent, dh.db)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc db*(dh: TxChainRef): BaseChainDB =
  ## Getter
  dh.db

proc config*(dh: TxChainRef): ChainConfig =
  ## Getter, shortcut for `dh.db.config`
  dh.db.config

proc head*(dh: TxChainRef): BlockHeader =
  ## Getter
  dh.parent

proc limits*(dh: TxChainRef): TxChainGasLimits =
  ## Getter
  dh.limits

proc miner*(dh: TxChainRef): EthAddress =
  ## Getter
  dh.miner

proc baseFee*(dh: TxChainRef): GasPrice =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  dh.child.baseFee

proc nextFork*(dh: TxChainRef): Fork =
  ## Getter, fork of next block
  dh.db.config.toFork(dh.parent.blockNumber + 1)

proc gasUsed*(dh: TxChainRef): GasInt =
  ## Getter, accumulated gas burned for collected blocks
  if 0 < dh.child.receipts.len:
    return dh.child.receipts[^1].cumulativeGasUsed

proc receipts*(dh: TxChainRef): seq[Receipt] =
  ## Getter, receipts for collected blocks
  dh.child.receipts

proc reward*(dh: TxChainRef): GasPriceEx =
  ## Getter, reward for collected blocks
  dh.child.reward

proc txRoot*(dh: TxChainRef): Hash256 =
  ## Getter, transaction state root hash for the next block header
  dh.child.txRoot

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `head=`*(dh: TxChainRef; val: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, updates descriptor. This setter re-positions the `vmState` and
  ## account caches to a new insertion point on the block chain database.
  dh.parent = val
  dh.update

proc miner*(dh: TxChainRef; val: EthAddress) =
  ## Setter
  dh.miner = val

proc `baseFee=`*(dh: TxChainRef; val: GasPrice) =
  ## Setter, temorarily overwrites parameter until next `head=` update. This
  ## function would be called in exceptional cases only as this parameter is
  ## determined by the `head=` update.
  dh.child.baseFee = val

proc `receipts=`*(dh: TxChainRef; val: seq[Receipt]) =
  ## Setter, implies `gasUsed`
  dh.child.receipts = val

proc `reward=`*(dh: TxChainRef; val: GasPriceEx) =
  ## Getter
  dh.child.reward = val

proc `txRoot=`*(dh: TxChainRef; val: Hash256) =
  ## Setter
  dh.child.txRoot = val

# ------------------------------------------------------------------------------
# Public functions, debugging & testing
# ------------------------------------------------------------------------------

proc setNextGasLimit*(dh: TxChainRef; val: GasInt) =
  ## Temorarily overwrite (until next header update). The argument might be
  ## adjusted so that it is in the proper range. This function
  ## is intended to support debugging and testing.
  dh.limits = dh.db.gasLimitsGet(dh.parent, val)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
