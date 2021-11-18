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
  ../utils/pow,
  ./gaslimit,
  chronicles,
  eth/[common, rlp, trie/trie_defs],
  ethash,
  nimcrypto,
  options,
  stew/[results, endians2]

from stew/byteutils
  import nil

export
  pow.PowRef,
  pow.init,
  results

const
  daoForkBlockExtraData =
    byteutils.hexToByteArray[13](DAOForkBlockExtra).toSeq

{.push raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

func isGenesis(header: BlockHeader): bool =
  header.blockNumber == 0.u256 and
    header.parentHash == GENESIS_PARENT_HASH

# ------------------------------------------------------------------------------
# Pivate validator functions
# ------------------------------------------------------------------------------

proc validateSeal(pow: PoWRef; header: BlockHeader): Result[void,string] =
  let (expMixDigest,miningValue) = pow.getPowDigest(header)

  if expMixDigest != header.mixDigest:
    let
      miningHash = header.getPowSpecs.miningHash
      (size, cachedHash) = pow.getPowCacheLookup(header.blockNumber)
    debug "mixHash mismatch",
      actual = header.mixDigest,
      expected = expMixDigest,
      blockNumber = header.blockNumber,
      miningHash = miningHash,
      nonce = header.nonce.toHex,
      difficulty = header.difficulty,
      size = size,
      cachedHash = cacheHash
    return err("mixHash mismatch")

  let value = Uint256.fromBytesBE(miningValue.data)
  if value > Uint256.high div header.difficulty:
    return err("mining difficulty error")

  ok()

proc validateHeader(db: BaseChainDB; header, parentHeader: BlockHeader;
                    numTransactions: int; checkSealOK: bool;
                    pow: PowRef): Result[void,string] =

  template inDAOExtraRange(blockNumber: BlockNumber): bool =
    # EIP-799
    # Blocks with block numbers in the range [1_920_000, 1_920_009]
    # MUST have DAOForkBlockExtra
    let DAOHigh = db.config.daoForkBlock + DAOForkExtraRange.u256
    db.config.daoForkBlock <= blockNumber and
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

  if db.config.daoForkSupport and inDAOExtraRange(header.blockNumber):
    if header.extraData != daoForkBlockExtraData:
      return err("header extra data should be marked DAO")

  let calcDiffc = db.config.calcDifficulty(header.timestamp, parentHeader)
  if header.difficulty < calcDiffc:
    return err("provided header difficulty is too low")

  if checkSealOK:
    return pow.validateSeal(header)

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

  let recentAncestorHashes = chainDB.getAncestorsHashes(
                               MAX_UNCLE_DEPTH + 1, header)
  let recentUncleHashes = chainDB.getUncleHashes(recentAncestorHashes)
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

    let uncleParent = chainDB.getBlockHeader(uncle.parentHash)
    result = validateUncle(header, uncle, uncleParent)
    if result.isErr:
      return

    result = chainDB.validateGasLimitOrBaseFee(uncle, uncleParent)
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

  if tx.txType == TxEip2930 and fork < FkBerlin:
    debug "invalid tx: Eip2930 Tx type detected before Berlin"
    return

  if tx.txType == TxEip1559 and fork < FkLondon:
    debug "invalid tx: Eip1559 Tx type detected before London"
    return

  if vmState.cumulativeGasUsed + tx.gasLimit > vmState.blockHeader.gasLimit:
    debug "invalid tx: block header gasLimit reached",
      maxLimit=vmState.blockHeader.gasLimit,
      gasUsed=vmState.cumulativeGasUsed,
      addition=tx.gasLimit
    return

  # ensure that the user was willing to at least pay the base fee
  let baseFee = vmState.blockHeader.baseFee.truncate(GasInt)
  if tx.maxFee < baseFee:
    debug "invalid tx: maxFee is smaller than baseFee",
      maxFee=tx.maxFee,
      baseFee=baseFee
    return

  # The total must be the larger of the two
  if tx.maxFee < tx.maxPriorityFee:
    debug "invalid tx: maxFee is smaller than maPriorityFee",
      maxFee=tx.maxFee,
      maxPriorityFee=tx.maxPriorityFee
    return

  # the signer must be able to afford the transaction
  let gasCost = if tx.txType >= TxEip1559:
                  tx.gasLimit.u256 * tx.maxFee.u256
                else:
                  tx.gasLimit.u256 * tx.gasPrice.u256

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
            pow: PowRef): Result[void,string] =
  if header.isGenesis:
    if header.extraData.len > 32:
      return err("BlockHeader.extraData larger than 32 bytes")
    return ok()

  let parent = chainDB.getBlockHeader(header.parentHash)
  result = chainDB.validateHeader(
    header, parent, numTransactions, checkSealOK, pow)
  if result.isErr:
    return

  if uncles.len > MAX_UNCLES:
    return err("Number of uncles exceed limit.")

  if not chainDB.exists(header.stateRoot):
    return err("`state_root` was not found in the db.")

  result = chainDB.validateUncles(header, uncles, checkSealOK, pow)
  if result.isOk:
    result = chainDB.validateGasLimitOrBaseFee(header, parent)


proc validateHeaderAndKinship*(chainDB: BaseChainDB;
                      header: BlockHeader; body: BlockBody; checkSealOK: bool;
                      pow: PowRef): Result[void,string] =
  chainDB.validateHeaderAndKinship(
    header, body.uncles, body.transactions.len, checkSealOK, pow)


proc validateHeaderAndKinship*(chainDB: BaseChainDB; ethBlock: EthBlock;
        checkSealOK: bool; pow: PowRef): Result[void,string] =
  chainDB.validateHeaderAndKinship(
    ethBlock.header, ethBlock.uncles, ethBlock.txs.len, checkSealOK, pow)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
