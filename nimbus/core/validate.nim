# Nimbus
# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[sequtils, sets, times],
  ../common/common,
  ../db/accounts_cache,
  ".."/[errors, transaction, vm_state, vm_types],
  "."/[dao, eip4844, gaslimit, withdrawals],
  ./pow/[difficulty, header],
  ./pow,
  chronicles,
  nimcrypto/utils,
  stew/[objects, results]

from stew/byteutils
  import nil

export
  pow.PowRef,
  pow.new,
  results

{.push raises: [].}

const
  daoForkBlockExtraData* =
    byteutils.hexToByteArray[13](DAOForkBlockExtra).toSeq

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

func isGenesis(header: BlockHeader): bool =
  header.blockNumber == 0.u256 and
    header.parentHash == GENESIS_PARENT_HASH

# ------------------------------------------------------------------------------
# Pivate validator functions
# ------------------------------------------------------------------------------

proc validateSeal(pow: PowRef; header: BlockHeader): Result[void,string] =
  let (expMixDigest, miningValue) = try:
    pow.getPowDigest(header)
  except CatchableError as err:
    return err("test")

  if expMixDigest != header.mixDigest:
    let
      miningHash = header.getPowSpecs.miningHash
      (size, cachedHash) = try: pow.getPowCacheLookup(header.blockNumber)
                           except KeyError: return err("Unknown block")
                           except CatchableError as e: return err(e.msg)
    debug "mixHash mismatch",
      actual = header.mixDigest,
      expected = expMixDigest,
      blockNumber = header.blockNumber,
      miningHash = miningHash,
      nonce = header.nonce.toHex,
      difficulty = header.difficulty,
      size = size,
      cachedHash = cachedHash
    return err("mixHash mismatch")

  let value = UInt256.fromBytesBE(miningValue.data)
  if value > UInt256.high div header.difficulty:
    return err("mining difficulty error")

  ok()

proc validateHeader(com: CommonRef; header, parentHeader: BlockHeader;
                    numTransactions: int; checkSealOK: bool;
                    pow: PowRef): Result[void,string] =

  template inDAOExtraRange(blockNumber: BlockNumber): bool =
    # EIP-799
    # Blocks with block numbers in the range [1_920_000, 1_920_009]
    # MUST have DAOForkBlockExtra
    let daoForkBlock = com.daoForkBlock.get
    let DAOHigh = daoForkBlock + DAOForkExtraRange.u256
    daoForkBlock <= blockNumber and
      blockNumber < DAOHigh

  if header.extraData.len > 32:
    return err("BlockHeader.extraData larger than 32 bytes")

  if header.gasUsed == 0 and 0 < numTransactions:
    return err("zero gasUsed but tranactions present");

  if header.gasUsed < 0 or header.gasUsed > header.gasLimit:
    return err("gasUsed should be non negative and smaller or equal gasLimit")

  if header.blockNumber != parentHeader.blockNumber + 1:
    return err("Blocks must be numbered consecutively")

  if header.timestamp.toUnix <= parentHeader.timestamp.toUnix:
    return err("timestamp must be strictly later than parent")

  if com.daoForkSupport and inDAOExtraRange(header.blockNumber):
    if header.extraData != daoForkBlockExtraData:
      return err("header extra data should be marked DAO")

  if com.consensus == ConsensusType.POS:
    # EIP-4399 and EIP-3675
    # no need to check mixDigest because EIP-4399 override this field
    # checking rule

    if not header.difficulty.isZero:
      return err("Non-zero difficulty in a post-merge block")

    if not header.nonce.isZeroMemory:
      return err("Non-zero nonce in a post-merge block")

    if header.ommersHash != EMPTY_UNCLE_HASH:
      return err("Invalid ommers hash in a post-merge block")
  else:
    let calcDiffc = com.calcDifficulty(header.timestamp, parentHeader)
    if header.difficulty < calcDiffc:
      return err("provided header difficulty is too low")

    if checkSealOK:
      return pow.validateSeal(header)

  ? com.validateWithdrawals(header)
  ? com.validateEip4844Header(header)

  ok()

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


proc validateUncles(com: CommonRef; header: BlockHeader;
                    uncles: seq[BlockHeader]; checkSealOK: bool;
                    pow: PowRef): Result[void,string] =
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
    let uncleHash = uncle.blockHash
    if uncleHash in uncleSet:
      return err("Block contains duplicate uncles")
    else:
      uncleSet.incl uncleHash

  let chainDB = com.db
  let recentAncestorHashes = try:
    chainDB.getAncestorsHashes(MAX_UNCLE_DEPTH + 1, header)
  except CatchableError as err:
    return err("Block not present in database")

  let recentUncleHashes = try:
    chainDB.getUncleHashes(recentAncestorHashes)
  except CatchableError as err:
    return err("Ancenstors not present in database")

  let blockHash = header.blockHash

  for uncle in uncles:
    let uncleHash = uncle.blockHash

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
      result = pow.validateSeal(uncle)
      if result.isErr:
        return

    let uncleParent = try:
      chainDB.getBlockHeader(uncle.parentHash)
    except BlockNotFound:
      return err("Uncle parent not found")

    result = validateUncle(header, uncle, uncleParent)
    if result.isErr:
      return

    result = com.validateGasLimitOrBaseFee(uncle, uncleParent)
    if result.isErr:
      return

  result = ok()

# ------------------------------------------------------------------------------
# Public function, extracted from executor
# ------------------------------------------------------------------------------

proc validateTransaction*(
    roDB:     ReadOnlyStateDB; ## Parent accounts environment for transaction
    tx:       Transaction;     ## tx to validate
    sender:   EthAddress;      ## tx.getSender or tx.ecRecover
    maxLimit: GasInt;          ## gasLimit from block header
    baseFee:  UInt256;         ## baseFee from block header
    fork:     EVMFork): bool =
  let
    balance = roDB.getBalance(sender)
    nonce = roDB.getNonce(sender)

  if tx.txType == TxEip2930 and fork < FkBerlin:
    debug "invalid tx: Eip2930 Tx type detected before Berlin"
    return false

  if tx.txType == TxEip1559 and fork < FkLondon:
    debug "invalid tx: Eip1559 Tx type detected before London"
    return false

  if fork >= FkShanghai and tx.contractCreation and tx.payload.len > EIP3860_MAX_INITCODE_SIZE:
    debug "invalid tx: initcode size exceeds maximum"
    return false

  # Note that the following check bears some plausibility but is _not_
  # covered by the eip-1559 reference (sort of) pseudo code, for details
  # see `https://eips.ethereum.org/EIPS/eip-1559#specification`_
  #
  # Rather this check is needed for surviving the post-London unit test
  # eth_tests/GeneralStateTests/stEIP1559/lowGasLimit.json which seems to
  # be sourced and generated from
  # eth_tests/src/GeneralStateTestsFiller/stEIP1559/lowGasLimitFiller.yml
  #
  # Interestingly, the hive tests do not use this particular test but rather
  # eth_tests/BlockchainTests/GeneralStateTests/stEIP1559/lowGasLimit.json
  # from a parallel tests series which look like somehow expanded versions.
  #
  # The parallel lowGasLimit.json test never triggers the case checked below
  # as the paricular transaction is omitted (the txs list is just set empty.)
  if maxLimit < tx.gasLimit:
    debug "invalid tx: block header gasLimit exceeded",
      maxLimit,
      gasLimit = tx.gasLimit
    return false

  # ensure that the user was willing to at least pay the base fee
  if tx.maxFee < baseFee.truncate(int64):
    debug "invalid tx: maxFee is smaller than baseFee",
      maxFee = tx.maxFee,
      baseFee
    return false

  # The total must be the larger of the two
  if tx.maxFee < tx.maxPriorityFee:
    debug "invalid tx: maxFee is smaller than maPriorityFee",
      maxFee         = tx.maxFee,
      maxPriorityFee = tx.maxPriorityFee
    return false

  # the signer must be able to fully afford the transaction
  let gasCost = if tx.txType >= TxEip1559:
                  tx.gasLimit.u256 * tx.maxFee.u256
                else:
                  tx.gasLimit.u256 * tx.gasPrice.u256

  if balance < gasCost:
    debug "invalid tx: not enough cash for gas",
      available = balance,
      require   = gasCost
    return false

  if balance - gasCost < tx.value:
    debug "invalid tx: not enough cash to send",
      available=balance,
      availableMinusGas=balance-gasCost,
      require=tx.value
    return false

  if tx.gasLimit < tx.intrinsicGas(fork):
    debug "invalid tx: not enough gas to perform calculation",
      available=tx.gasLimit,
      require=tx.intrinsicGas(fork)
    return false

  if tx.nonce != nonce:
    debug "invalid tx: account nonce mismatch",
      txNonce=tx.nonce,
      accountNonce=nonce
    return false

  if tx.nonce == high(uint64):
    debug "invalid tx: nonce at maximum"
    return false

  # EIP-3607 Reject transactions from senders with deployed code
  # The EIP spec claims this attack never happened before
  # Clients might choose to disable this rule for RPC calls like
  # `eth_call` and `eth_estimateGas`
  # EOA = Externally Owned Account
  let codeHash = roDB.getCodeHash(sender)
  if codeHash != EMPTY_SHA3:
    debug "invalid tx: sender is not an EOA",
      sender=sender.toHex,
      codeHash=codeHash.data.toHex
    return false

  true

proc validateTransaction*(
    vmState: BaseVMState;  ## Parent accounts environment for transaction
    tx:      Transaction;  ## tx to validate
    sender:  EthAddress;   ## tx.getSender or tx.ecRecover
    header:  BlockHeader;  ## Header for the block containing the current tx
    fork:    EVMFork): bool =
  ## Variant of `validateTransaction()`
  let
    roDB = vmState.readOnlyStateDB
    gasLimit = header.gasLimit
    baseFee = header.baseFee
  roDB.validateTransaction(tx, sender, gasLimit, baseFee, fork)

# ------------------------------------------------------------------------------
# Public functions, extracted from test_blockchain_json
# ------------------------------------------------------------------------------

proc validateHeaderAndKinship*(
    com: CommonRef;
    header: BlockHeader;
    uncles: seq[BlockHeader];
    numTransactions: int;
    checkSealOK: bool;
    pow: PowRef): Result[void, string] =
  if header.isGenesis:
    if header.extraData.len > 32:
      return err("BlockHeader.extraData larger than 32 bytes")
    return ok()

  let chainDB = com.db
  let parent = try:
    chainDB.getBlockHeader(header.parentHash)
  except CatchableError as err:
    return err("Failed to load block header from DB")

  result = com.validateHeader(
    header, parent, numTransactions, checkSealOK, pow)
  if result.isErr:
    return

  if uncles.len > MAX_UNCLES:
    return err("Number of uncles exceed limit.")

  if not chainDB.exists(header.stateRoot):
    return err("`state_root` was not found in the db.")

  if com.consensus != ConsensusType.POS:
    result = com.validateUncles(header, uncles, checkSealOK, pow)

  if result.isOk:
    result = com.validateGasLimitOrBaseFee(header, parent)

proc validateHeaderAndKinship*(
    com: CommonRef;
    header: BlockHeader;
    body: BlockBody;
    checkSealOK: bool;
    pow: PowRef): Result[void, string] =

  com.validateHeaderAndKinship(
    header, body.uncles, body.transactions.len, checkSealOK, pow)

proc validateHeaderAndKinship*(
    com: CommonRef;
    ethBlock: EthBlock;
    checkSealOK: bool;
    pow: PowRef): Result[void,string] =
  com.validateHeaderAndKinship(
    ethBlock.header, ethBlock.uncles, ethBlock.txs.len,
    checkSealOK, pow)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
