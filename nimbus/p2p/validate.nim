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
  ../constants,
  ../db/[db_chain, accounts_cache],
  ../errors,
  ../transaction,
  ../utils,
  ../utils/header,
  ../vm_state,
  ../vm_types,
  ../vm_types2,
  chronicles,
  eth/[common, rlp],
  eth/trie/trie_defs,
  ethash,
  nimcrypto,
  options,
  sets,
  stew/endians2,
  strutils,
  tables,
  times

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

const
  CACHE_MAX_ITEMS = 10

var cacheByEpoch = initOrderedTable[uint64, seq[Hash512]]()

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc mkCacheBytes(blockNumber: uint64): seq[Hash512] =
  mkcache(getCacheSize(blockNumber), getSeedhash(blockNumber))


proc getCache(blockNumber: uint64): seq[Hash512] =
  # TODO: this is very inefficient
  let epochIndex = blockNumber div EPOCH_LENGTH

  # Get the cache if already generated, marking it as recently used
  if epochIndex in cacheByEpoch:
    let c = cacheByEpoch[epochIndex]
    cacheByEpoch.del(epochIndex)  # pop and append at end
    cacheByEpoch[epochIndex] = c
    return c

  # Generate the cache if it was not already in memory
  # Simulate requesting mkcache by block number: multiply index by epoch length
  let c = mkCacheBytes(epochIndex * EPOCH_LENGTH)
  cacheByEpoch[epochIndex] = c

  # Limit memory usage for cache
  if cacheByEpoch.len > CACHE_MAX_ITEMS:
    cacheByEpoch.del(epochIndex)

  shallowCopy(result, c)


func cacheHash(x: openArray[Hash512]): Hash256 =
  var ctx: keccak256
  ctx.init()

  for a in x:
    ctx.update(a.data[0].unsafeAddr, uint(a.data.len))

  ctx.finish result.data
  ctx.clear()


proc checkPOW(blockNumber: Uint256, miningHash, mixHash: Hash256,
              nonce: BlockNonce, difficulty: DifficultyInt) =
  let blockNumber = blockNumber.truncate(uint64)
  let cache = blockNumber.getCache()

  let size = getDataSize(blockNumber)
  let miningOutput = hashimotoLight(
    size, cache, miningHash, uint64.fromBytesBE(nonce))
  if miningOutput.mixDigest != mixHash:
    echo "actual: ", miningOutput.mixDigest
    echo "expected: ", mixHash
    echo "blockNumber: ", blockNumber
    echo "miningHash: ", miningHash
    echo "nonce: ", nonce.toHex
    echo "difficulty: ", difficulty
    echo "size: ", size
    echo "cache hash: ", cacheHash(cache)
    raise newException(ValidationError, "mixHash mismatch")

  let value = Uint256.fromBytesBE(miningOutput.value.data)
  if value > Uint256.high div difficulty:
    raise newException(ValidationError, "mining difficulty error")


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


proc validateSeal(header: BlockHeader) =
  let miningHeader = header.toMiningHeader
  let miningHash = miningHeader.hash

  checkPOW(header.blockNumber, miningHash,
           header.mixDigest, header.nonce, header.difficulty)

# ------------------------------------------------------------------------------
# Puplic function, extracted from executor
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

func validateGasLimit*(gasLimit, parentGasLimit: GasInt) =
  if gasLimit < GAS_LIMIT_MINIMUM:
    raise newException(ValidationError, "Gas limit is below minimum")
  if gasLimit > GAS_LIMIT_MAXIMUM:
    raise newException(ValidationError, "Gas limit is above maximum")
  let diff = gasLimit - parentGasLimit
  if diff > (parentGasLimit div GAS_LIMIT_ADJUSTMENT_FACTOR):
    raise newException(
      ValidationError, "Gas limit difference to parent is too big")


proc validateHeader*(header, parentHeader: BlockHeader, checkSeal: bool) =
  if header.extraData.len > 32:
    raise newException(
      ValidationError, "BlockHeader.extraData larger than 32 bytes")

  validateGasLimit(header.gasLimit, parentHeader.gasLimit)

  if header.blockNumber != parentHeader.blockNumber + 1:
    raise newException(
      ValidationError, "Blocks must be numbered consecutively.")

  if header.timestamp.toUnix <= parentHeader.timestamp.toUnix:
    raise newException(
      ValidationError, "timestamp must be strictly later than parent")

  if checkSeal:
    validateSeal(header)


func validateUncle*(currBlock, uncle, uncleParent: BlockHeader) =
  if uncle.blockNumber >= currBlock.blockNumber:
    raise newException(
      ValidationError, "uncle block number larger than current block number")

  if uncle.blockNumber != uncleParent.blockNumber + 1:
    raise newException(
      ValidationError, "Uncle number is not one above ancestor's number")

  if uncle.timestamp.toUnix < uncleParent.timestamp.toUnix:
    raise newException(
      ValidationError, "Uncle timestamp is before ancestor's timestamp")

  if uncle.gasUsed > uncle.gasLimit:
    raise newException(ValidationError, "Uncle's gas usage is above the limit")


proc validateGasLimit*(chainDB: BaseChainDB, header: BlockHeader) =
  let parentHeader = chainDB.getBlockHeader(header.parentHash)
  let (lowBound, highBound) = gasLimitBounds(parentHeader)

  if header.gasLimit < lowBound:
    raise newException(ValidationError, "The gas limit is too low")
  elif header.gasLimit > highBound:
    raise newException(ValidationError, "The gas limit is too high")


proc validateUncles*(chainDB: BaseChainDB,
                    currBlock: EthBlock, checkSeal: bool) =
  let hasUncles = currBlock.uncles.len > 0
  let shouldHaveUncles = currBlock.header.ommersHash != EMPTY_UNCLE_HASH

  if not hasUncles and not shouldHaveUncles:
    # optimization to avoid loading ancestors from DB, since the block has
    # no uncles
    return
  elif hasUncles and not shouldHaveUncles:
    raise newException(
      ValidationError,
      "Block has uncles but header suggests uncles should be empty")
  elif shouldHaveUncles and not hasUncles:
    raise newException(
      ValidationError,
      "Header suggests block should have uncles but block has none")

  # Check for duplicates
  var uncleSet = initHashSet[Hash256]()
  for uncle in currBlock.uncles:
    let uncleHash = uncle.hash
    if uncleHash in uncleSet:
      raise newException(ValidationError, "Block contains duplicate uncles")
    else:
      uncleSet.incl uncleHash

  let recentAncestorHashes = chainDB.getAncestorsHashes(
                               MAX_UNCLE_DEPTH + 1, currBlock.header)
  let recentUncleHashes = chainDB.getUncleHashes(recentAncestorHashes)
  let blockHash =currBlock.header.hash

  for uncle in currBlock.uncles:
    let uncleHash = uncle.hash

    if uncleHash == blockHash:
      raise newException(ValidationError, "Uncle has same hash as block")

    # ensure the uncle has not already been included.
    if uncleHash in recentUncleHashes:
      raise newException(ValidationError, "Duplicate uncle")

    # ensure that the uncle is not one of the canonical chain blocks.
    if uncleHash in recentAncestorHashes:
      raise newException(ValidationError, "Uncle cannot be an ancestor")

    # ensure that the uncle was built off of one of the canonical chain
    # blocks.
    if (uncle.parentHash notin recentAncestorHashes) or
       (uncle.parentHash == currBlock.header.parentHash):
      raise newException(ValidationError, "Uncle's parent is not an ancestor")

    # Now perform VM level validation of the uncle
    if checkSeal:
      validateSeal(uncle)

    let uncleParent = chainDB.getBlockHeader(uncle.parentHash)
    validateUncle(currBlock.header, uncle, uncleParent)


func isGenesis*(currBlock: EthBlock): bool =
  result = currBlock.header.blockNumber == 0.u256 and
           currBlock.header.parentHash == GENESIS_PARENT_HASH


proc validateBlock*(chainDB: BaseChainDB,
                    currBlock: EthBlock, checkSeal: bool): bool =
  if currBlock.isGenesis:
    if currBlock.header.extraData.len > 32:
      raise newException(
        ValidationError, "BlockHeader.extraData larger than 32 bytes")
    return true

  let parentHeader = chainDB.getBlockHeader(currBlock.header.parentHash)
  validateHeader(currBlock.header, parentHeader, checkSeal)

  if currBlock.uncles.len > MAX_UNCLES:
    raise newException(ValidationError, "Number of uncles exceed limit.")

  if not chainDB.exists(currBlock.header.stateRoot):
    raise newException(
      ValidationError, "`state_root` was not found in the db.")

  validateUncles(chainDB, currBlock, checkSeal)
  validateGaslimit(chainDB, currBlock.header)

  result = true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
