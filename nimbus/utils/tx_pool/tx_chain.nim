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
  ./tx_chain/[tx_basefee, tx_gaslimits, tx_vmstate],
  ./tx_item,
  eth/[common],
  nimcrypto

{.push raises: [Defect].}

type
  TxChainRef* = ref object ##\
    ## Cache the state of the block chain which serves as logical insertion
    ## point for a new block. This state is typically the canonical head
    ## when updated.
    vmState: BaseVMState       ## Block chain working environmnt
    miner: EthAddress          ## Address of fee beneficiary
    nextBaseFee: GasPrice      ## Base fee derived from `head`
    nextTxRoot: Hash256        ## To be used in next block header
    nextGas: TxPoolGasLimits   ## Gas limits for packer and next header

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc update(dh: TxChainRef) =
  let
    db = dh.vmState.chainDB
    header = dh.vmState.blockHeader
  dh.nextBaseFee = db.config.baseFeeGet(header)
  dh.nextTxRoot = BLANK_ROOT_HASH
  dh.nextGas = dh.vmState.gasLimitsGet(header.gasLimit)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxChainRef; db: BaseChainDB; miner: EthAddress): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor
  new result
  result.vmState = db.vmStateGet(db.getCanonicalHead)
  result.miner = miner
  result.update

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getBalance*(dh: TxChainRef; account: EthAddress): UInt256
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getBalance()`
  dh.vmState.readOnlyStateDB.getBalance(account)

proc getNonce*(dh: TxChainRef; account: EthAddress): AccountNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getNonce()`
  dh.vmState.readOnlyStateDB.getNonce(account)


proc getHeader*(dh: TxChainRef): BlockHeader
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Generate a new header, a child of the cached `head` (similar to
  ## `utils.generateHeaderFromParentHeader()`.)

  let
    vmState = dh.vmState
    config = vmState.chainDB.config
    gasUsed = vmState.cumulativeGasUsed
    blockNumber = vmState.blockHeader.blockNumber + 1
    fork = config.toFork(blockNumber)
    tStamp = getTime().utc.toTime

    effGasLimit = if dh.nextGas.trgLimit < gasUsed:   dh.nextGas.maxLimit
                  elif gasUsed < dh.nextGas.minLimit: dh.nextGas.minLimit
                  else:                               gasUsed

    feeOption = if FkLondon <= fork: some(dh.nextBaseFee.uint64.u256)
                else:                UInt256.none()

  BlockHeader(
    parentHash:  vmState.blockHeader.blockHash,
    ommersHash:  EMPTY_UNCLE_HASH,
    coinbase:    dh.miner,
    stateRoot:   vmState.blockHeader.stateRoot,
    txRoot:      dh.nextTxRoot,
    receiptRoot: vmState.receipts.calcReceiptRoot,
    bloom:       vmState.receipts.createBloom,
    difficulty:  config.calcDifficulty(tStamp, vmState.blockHeader),
    blockNumber: vmState.blockHeader.blockNumber + 1,
    gasLimit:    effGasLimit,
    gasUsed:     vmState.cumulativeGasUsed,
    timestamp:   tStamp,
    # extraData: Blob       # signing data
    # mixDigest: Hash256    # mining hash for given difficulty
    # nonce:     BlockNonce # mining free vaiable
    fee:         feeOption)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc db*(dh: TxChainRef): BaseChainDB =
  ## Getter
  dh.vmState.chainDB

proc config*(dh: TxChainRef): ChainConfig =
  ## Getter, shortcut for `dh.db.config`
  dh.vmState.chainDB.config

proc head*(dh: TxChainRef): BlockHeader =
  ## Getter, current
  dh.vmState.blockHeader

proc lwmGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.nextGas.lwmLimit

proc miner*(dh: TxChainRef): EthAddress =
  ## Getter
  dh.miner

proc nextBaseFee*(dh: TxChainRef): GasPrice =
  ## Getter, baseFee of next bock
  dh.nextBaseFee

proc nextFork*(dh: TxChainRef): Fork =
  ## Getter, fork of next block
  dh.vmState.chainDB.config.toFork(dh.vmState.blockHeader.blockNumber + 1)

proc nextTxRoot*(dh: TxChainRef): Hash256 =
  ## Getter, transaction state root hash for the next header
  dh.nextTxRoot

proc maxGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.nextGas.maxLimit

proc minGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.nextGas.minLimit

proc trgGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.nextGas.trgLimit

proc vmState*(dh: TxChainRef; pristine = false): BaseVMState
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Gettercurrent block chain state. If the `pristine` argument is set
  ## `true`, a new clean copy is cached and returned.
  if pristine:
    let db = dh.vmState.chainDB
    dh.vmState = db.vmStateGet(dh.vmState.blockHeader)
  dh.vmState

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `nextBaseFee=`*(dh: TxChainRef; val: GasPrice) =
  ## Setter, temorarily overwrites parameter until next `head=` update. This
  ## function would be called in exceptional cases only as this parameter is
  ## determined by the `head=` update.
  dh.nextBaseFee = val

proc `head=`*(dh: TxChainRef; val: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, updates descriptor. This setter re-positions the `vmState` and
  ## account caches to a new insertion point on the block chain database.
  let db = dh.vmState.chainDB
  dh.vmState = db.vmStateGet(val)
  dh.update

proc miner*(dh: TxChainRef; val: EthAddress) =
  ## Setter
  dh.miner = val

proc `nextTxRoot=`*(dh: TxChainRef; val: Hash256) =
  ## Setter
  dh.nextTxRoot = val

# ------------------------------------------------------------------------------
# Public functions, debugging & testing
# ------------------------------------------------------------------------------

proc setNextGasLimit*(dh: TxChainRef; val: GasInt) =
  ## Temorarily overwrite (until next header update). The argument might be
  ## adjusted so that it is in the proper range. This function
  ## is intended to support debugging and testing.
  dh.nextGas = dh.vmState.gasLimitsGet(val)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
