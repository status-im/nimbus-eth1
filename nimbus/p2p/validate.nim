# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[sequtils, sets, tables, times],
  ../constants,
  ../db/[db_chain, accounts_cache],
  ../transaction,
  ../utils,
  ../utils/[difficulty, header],
  ../vm_state,
  ../vm_types,
  ../forks,
  ./dao,
  ./validate/epoch_hash_cache,
  chronicles,
  eth/[common, rlp, trie/trie_defs],
  ethash,
  nimcrypto,
  options,
  stew/[results, endians2]

from stew/byteutils
  import nil

export
  epoch_hash_cache.EpochHashCache,
  epoch_hash_cache.initEpochHashCache,
  results

const
  daoForkBlockExtraData =
    byteutils.hexToByteArray[13](DAOForkBlockExtra).toSeq

type
  MiningHeader = object
    parentHash  : Hash256
    ommersHash  : Hash256
    coinbase    : EthAddress
    stateRoot   : Hash256
    txRoot      : Hash256
    receiptRoot : Hash256
    bloom       : common.BloomFilter
    difficulty  : DifficultyInt
    blockNumber : BlockNumber
    gasLimit    : GasInt
    gasUsed     : GasInt
    timestamp   : EthTime
    extraData   : Blob

  Hash512 = MDigest[512]

{.push raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

func toMiningHeader(header: BlockHeader): MiningHeader =
  result.parentHash  = header.parentHash
  result.ommersHash  = header.ommersHash
  result.coinbase    = header.coinbase
  result.stateRoot   = header.stateRoot
  result.txRoot      = header.txRoot
  result.receiptRoot = header.receiptRoot
  result.bloom       = header.bloom
  result.difficulty  = header.difficulty
  result.blockNumber = header.blockNumber
  result.gasLimit    = header.gasLimit
  result.gasUsed     = header.gasUsed
  result.timestamp   = header.timestamp
  result.extraData   = header.extraData


func hash(header: MiningHeader): Hash256 =
  keccakHash(rlp.encode(header))

func isGenesis(header: BlockHeader): bool =
  header.blockNumber == 0.u256 and
    header.parentHash == GENESIS_PARENT_HASH

# ------------------------------------------------------------------------------
# Private cache management functions
# ------------------------------------------------------------------------------

func cacheHash(x: EpochHashDigest): Hash256 =
  var ctx: keccak256
  ctx.init()

  for a in x:
    ctx.update(a.data[0].unsafeAddr, uint(a.data.len))

  ctx.finish result.data
  ctx.clear()

# ------------------------------------------------------------------------------
# Pivate validator functions
# ------------------------------------------------------------------------------

proc checkPOW(blockNumber: Uint256; miningHash, mixHash: Hash256;
              nonce: BlockNonce; difficulty: DifficultyInt;
              hashCache: var EpochHashCache): Result[void,string] =
  let
    blockNumber = blockNumber.truncate(uint64)
    cache = hashCache.getEpochHash(blockNumber)
    size = getDataSize(blockNumber)
    miningOutput = hashimotoLight(
      size, cache, miningHash, uint64.fromBytesBE(nonce))

  if miningOutput.mixDigest != mixHash:
    debug "mixHash mismatch",
      actual = miningOutput.mixDigest,
      expected = mixHash,
      blockNumber = blockNumber,
      miningHash = miningHash,
      nonce = nonce.toHex,
      difficulty = difficulty,
      size = size,
      cachedHash = cacheHash(cache)
    return err("mixHash mismatch")

  let value = Uint256.fromBytesBE(miningOutput.value.data)
  if value > Uint256.high div difficulty:
    return err("mining difficulty error")

  result = ok()


proc validateSeal(hashCache: var EpochHashCache;
                  header: BlockHeader): Result[void,string] =
  let miningHeader = header.toMiningHeader
  let miningHash = miningHeader.hash

  checkPOW(header.blockNumber, miningHash,
           header.mixDigest, header.nonce, header.difficulty, hashCache)


proc validateGasLimit(chainDB: BaseChainDB;
                      header: BlockHeader): Result[void,string] =
  let parentHeader = chainDB.getBlockHeader(header.parentHash)
  let (lowBound, highBound) = gasLimitBounds(parentHeader)

  if header.gasLimit < lowBound:
    return err("The gas limit is too low")
  if header.gasLimit > highBound:
    return err("The gas limit is too high")

  result = ok()


func validateGasLimit(gasLimit, parentGasLimit: GasInt): Result[void,string] =
  if gasLimit < GAS_LIMIT_MINIMUM:
    return err("Gas limit is below minimum")
  if gasLimit > GAS_LIMIT_MAXIMUM:
    return err("Gas limit is above maximum")

  let diff = gasLimit - parentGasLimit
  if diff > (parentGasLimit div GAS_LIMIT_ADJUSTMENT_FACTOR):
    return err("Gas limit difference to parent is too big")

  result = ok()

proc validateHeader(db: BaseChainDB; header, parentHeader: BlockHeader;
                    numTransactions: int; checkSealOK: bool;
                    hashCache: var EpochHashCache): Result[void,string] =
  if header.extraData.len > 32:
    return err("BlockHeader.extraData larger than 32 bytes")

  result = validateGasLimit(header.gasLimit, parentHeader.gasLimit)
  if result.isErr:
    return

  if header.gasUsed == 0 and 0 < numTransactions:
    return err("zero gasUsed but tranactions present");

  if header.blockNumber != parentHeader.blockNumber + 1:
    return err("Blocks must be numbered consecutively")

  if header.timestamp.toUnix <= parentHeader.timestamp.toUnix:
    return err("timestamp must be strictly later than parent")

  if db.config.daoForkSupport and
     db.config.daoForkBlock <= header.blockNumber and
     header.extraData != daoForkBlockExtraData:
    return err("header extra data should be marked DAO")

  let calcDiffc = db.config.calcDifficulty(header.timestamp, parentHeader)
  if header.difficulty < calcDiffc:
    return err("provided header difficulty is too low")

  if checkSealOK:
    return hashCache.validateSeal(header)

  result = ok()


func validateUncle(currBlock, uncle, uncleParent: BlockHeader):
                                               Result[void,string] =
  if uncle.blockNumber >= currBlock.blockNumber:
    return err("uncle block number larger than current block number")

  if uncle.blockNumber != uncleParent.blockNumber + 1:
    return err("Uncle number is not one above ancestor's number")

  if uncle.timestamp.toUnix < uncleParent.timestamp.toUnix:
    return err("Uncle timestamp is before ancestor's timestamp")

  if uncle.gasUsed > uncle.gasLimit:
    return err("Uncle's gas usage is above the limit")

  result = ok()


proc validateUncles(chainDB: BaseChainDB; header: BlockHeader;
                    uncles: seq[BlockHeader]; checkSealOK: bool;
                    hashCache: var EpochHashCache): Result[void,string] =
  let hasUncles = uncles.len > 0
  let shouldHaveUncles = header.ommersHash != EMPTY_UNCLE_HASH

  if not hasUncles and not shouldHaveUncles:
    # optimization to avoid loading ancestors from DB, since the block has
    # no uncles
    return ok()
  if hasUncles and not shouldHaveUncles:
    return err("Block has uncles but header suggests uncles should be empty")
  if shouldHaveUncles and not hasUncles:
    return err("Header suggests block should have uncles but block has none")

  # Check for duplicates
  var uncleSet = initHashSet[Hash256]()
  for uncle in uncles:
    let uncleHash = uncle.hash
    if uncleHash in uncleSet:
      return err("Block contains duplicate uncles")
    else:
      uncleSet.incl uncleHash

  let recentAncestorHashes = chainDB.getAncestorsHashes(
                               MAX_UNCLE_DEPTH + 1, header)
  let recentUncleHashes = chainDB.getUncleHashes(recentAncestorHashes)
  let blockHash = header.hash

  for uncle in uncles:
    let uncleHash = uncle.hash

    if uncleHash == blockHash:
      return err("Uncle has same hash as block")

    # ensure the uncle has not already been included.
    if uncleHash in recentUncleHashes:
      return err("Duplicate uncle")

    # ensure that the uncle is not one of the canonical chain blocks.
    if uncleHash in recentAncestorHashes:
      return err("Uncle cannot be an ancestor")

    # ensure that the uncle was built off of one of the canonical chain
    # blocks.
    if (uncle.parentHash notin recentAncestorHashes) or
       (uncle.parentHash == header.parentHash):
      return err("Uncle's parent is not an ancestor")

    # check uncle against own parent
    var parent: BlockHeader
    if not chainDB.getBlockHeader(uncle.parentHash,parent):
      return err("Uncle's parent has gone missing")
    if uncle.timestamp <= parent.timestamp:
      return err("Uncle's parent must me older")

    # Now perform VM level validation of the uncle
    if checkSealOK:
      result = hashCache.validateSeal(uncle)
      if result.isErr:
        return

    let uncleParent = chainDB.getBlockHeader(uncle.parentHash)
    result = validateUncle(header, uncle, uncleParent)
    if result.isErr:
      return

  result = ok()

# ------------------------------------------------------------------------------
# Public function, extracted from executor
# ------------------------------------------------------------------------------

proc validateTransaction*(vmState: BaseVMState, tx: Transaction,
                          sender: EthAddress, fork: Fork): bool =
  let balance = vmState.readOnlyStateDB.getBalance(sender)
  let nonce = vmState.readOnlyStateDB.getNonce(sender)

  if vmState.cumulativeGasUsed + tx.gasLimit > vmState.blockHeader.gasLimit:
    debug "invalid tx: block header gasLimit reached",
      maxLimit=vmState.blockHeader.gasLimit,
      gasUsed=vmState.cumulativeGasUsed,
      addition=tx.gasLimit
    return

  let gasCost = tx.gasLimit.u256 * tx.gasPrice.u256
  if gasCost > balance:
    debug "invalid tx: not enough cash for gas",
      available=balance,
      require=gasCost
    return

  if tx.value > balance - gasCost:
    debug "invalid tx: not enough cash to send",
      available=balance,
      availableMinusGas=balance-gasCost,
      require=tx.value
    return

  if tx.gasLimit < tx.intrinsicGas(fork):
    debug "invalid tx: not enough gas to perform calculation",
      available=tx.gasLimit,
      require=tx.intrinsicGas(fork)
    return

  if tx.nonce != nonce:
    debug "invalid tx: account nonce mismatch",
      txNonce=tx.nonce,
      accountNonce=nonce
    return

  result = true

# ------------------------------------------------------------------------------
# Public functions, extracted from test_blockchain_json
# ------------------------------------------------------------------------------

proc validateHeaderAndKinship*(chainDB: BaseChainDB; header: BlockHeader;
            uncles: seq[BlockHeader]; numTransactions: int; checkSealOK: bool;
            hashCache: var EpochHashCache): Result[void,string] =
  if header.isGenesis:
    if header.extraData.len > 32:
      return err("BlockHeader.extraData larger than 32 bytes")
    return ok()

  let parentHeader = chainDB.getBlockHeader(header.parentHash)
  result = chainDB.validateHeader(
    header, parentHeader,numTransactions,  checkSealOK, hashCache)
  if result.isErr:
    return

  if uncles.len > MAX_UNCLES:
    return err("Number of uncles exceed limit.")

  if not chainDB.exists(header.stateRoot):
    return err("`state_root` was not found in the db.")

  result = chainDB.validateUncles(header, uncles, checkSealOK, hashCache)
  if result.isOk:
    result = chainDB.validateGaslimit(header)


proc validateHeaderAndKinship*(chainDB: BaseChainDB;
                      header: BlockHeader; body: BlockBody; checkSealOK: bool;
                      hashCache: var EpochHashCache): Result[void,string] =
  chainDB.validateHeaderAndKinship(
    header, body.uncles, body.transactions.len, checkSealOK, hashCache)


proc validateHeaderAndKinship*(chainDB: BaseChainDB; ethBlock: EthBlock;
        checkSealOK: bool; hashCache: var EpochHashCache): Result[void,string] =
  chainDB.validateHeaderAndKinship(
    ethBlock.header, ethBlock.uncles, ethBlock.txs.len, checkSealOK, hashCache)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
