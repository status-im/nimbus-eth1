# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[sequtils, sets, strutils],
  ../db/ledger,
  ".."/[transaction, common/common],
  ".."/[errors],
  ../utils/utils,
  "."/[dao, eip4844, gaslimit, withdrawals],
  ./pow/[difficulty, header],
  ./pow,
  nimcrypto/utils as cryptoutils,
  stew/objects,
  results

from stew/byteutils
  import nil

export
  results

const
  daoForkBlockExtraData* =
    byteutils.hexToByteArray[13](DAOForkBlockExtra).toSeq

# ------------------------------------------------------------------------------
# Pivate validator functions
# ------------------------------------------------------------------------------

proc validateSeal(pow: PowRef; header: BlockHeader): Result[void,string] =
  try:
    let (expmixHash, miningValue) = pow.getPowDigest(header)

    if expmixHash != header.mixHash:
      let
        miningHash = header.getPowSpecs.miningHash
        (size, cachedHash) = try: pow.getPowCacheLookup(header.number)
                            except KeyError: return err("Unknown block")
                            except CatchableError as e: return err(e.msg)
      return err("mixHash mismatch. actual=$1, expected=$2," &
                " blockNumber=$3, miningHash=$4, nonce=$5, difficulty=$6," &
                " size=$7, cachedHash=$8" % [
                $header.mixHash, $expmixHash, $header.number,
                $miningHash, header.nonce.toHex, $header.difficulty,
                $size, $cachedHash])

    let value = UInt256.fromBytesBE(miningValue.data)
    if value > UInt256.high div header.difficulty:
      return err("mining difficulty error")

  except CatchableError as err:
    return err(err.msg)

  ok()

proc validateHeader(
    com: CommonRef;
    blk: EthBlock;
    parentHeader: BlockHeader;
    checkSealOK: bool;
      ): Result[void,string] =
  template header: BlockHeader = blk.header
  # TODO this code is used for validating uncles also, though these get passed
  #      an empty body - avoid this by separating header and block validation
  template inDAOExtraRange(blockNumber: BlockNumber): bool =
    # EIP-799
    # Blocks with block numbers in the range [1_920_000, 1_920_009]
    # MUST have DAOForkBlockExtra
    let daoForkBlock = com.daoForkBlock.get
    let DAOHigh = daoForkBlock + DAOForkExtraRange
    daoForkBlock <= blockNumber and
      blockNumber < DAOHigh

  if header.extraData.len > 32:
    return err("BlockHeader.extraData larger than 32 bytes")

  if header.gasUsed == 0 and 0 < blk.transactions.len:
    return err("zero gasUsed but transactions present");

  if header.gasUsed < 0 or header.gasUsed > header.gasLimit:
    return err("gasUsed should be non negative and smaller or equal gasLimit")

  if header.number != parentHeader.number + 1:
    return err("Blocks must be numbered consecutively")

  if header.timestamp <= parentHeader.timestamp:
    return err("timestamp must be strictly later than parent")

  if com.daoForkSupport and inDAOExtraRange(header.number):
    if header.extraData != daoForkBlockExtraData:
      return err("header extra data should be marked DAO")

  if com.consensus == ConsensusType.POS:
    # EIP-4399 and EIP-3675
    # no need to check mixHash because EIP-4399 override this field
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
      return com.pow.validateSeal(header)

  ? com.validateWithdrawals(header, blk.withdrawals)
  ? com.validateEip4844Header(header, parentHeader, blk.transactions)
  ? com.validateGasLimitOrBaseFee(header, parentHeader)

  ok()

proc validateUncles(com: CommonRef; header: BlockHeader;
                    uncles: openArray[BlockHeader];
                    checkSealOK: bool): Result[void,string]
                      {.gcsafe, raises: [].} =
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
  var uncleSet = HashSet[Hash256]()
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

    if uncle.number >= header.number:
      return err("uncle block number larger than current block number")

    # check uncle against own parent
    var parent: BlockHeader
    if not chainDB.getBlockHeader(uncle.parentHash,parent):
      return err("Uncle's parent has gone missing")
    if uncle.timestamp <= parent.timestamp:
      return err("Uncle's parent must me older")

    # Now perform VM level validation of the uncle
    if checkSealOK:
      ? com.pow.validateSeal(uncle)

    let uncleParent = try:
      chainDB.getBlockHeader(uncle.parentHash)
    except BlockNotFound:
      return err("Uncle parent not found")

    ? com.validateHeader(
      EthBlock.init(uncle, BlockBody()), uncleParent, checkSealOK)

  ok()

# ------------------------------------------------------------------------------
# Public function, extracted from executor
# ------------------------------------------------------------------------------

func gasCost*(tx: Transaction): UInt256 =
  if tx.txType >= TxEip4844:
    tx.gasLimit.u256 * tx.maxFeePerGas.u256 + tx.getTotalBlobGas.u256 * tx.maxFeePerBlobGas
  elif tx.txType >= TxEip1559:
    tx.gasLimit.u256 * tx.maxFeePerGas.u256
  else:
    tx.gasLimit.u256 * tx.gasPrice.u256

proc validateTxBasic*(
    tx:       Transaction;     ## tx to validate
    fork:     EVMFork,
    validateFork: bool = true): Result[void, string] =

  if validateFork:
    if tx.txType == TxEip2930 and fork < FkBerlin:
      return err("invalid tx: Eip2930 Tx type detected before Berlin")

    if tx.txType == TxEip1559 and fork < FkLondon:
      return err("invalid tx: Eip1559 Tx type detected before London")

    if tx.txType == TxEip4844 and fork < FkCancun:
      return err("invalid tx: Eip4844 Tx type detected before Cancun")

  if fork >= FkShanghai and tx.contractCreation and tx.payload.len > EIP3860_MAX_INITCODE_SIZE:
    return err("invalid tx: initcode size exceeds maximum")

  try:
    # The total must be the larger of the two
    if tx.maxFeePerGas < tx.maxPriorityFeePerGas:
      return err("invalid tx: maxFee is smaller than maPriorityFee. maxFee=$1, maxPriorityFee=$2" % [
        $tx.maxFeePerGas, $tx.maxPriorityFeePerGas])

    if tx.gasLimit < tx.intrinsicGas(fork):
      return err("invalid tx: not enough gas to perform calculation. avail=$1, require=$2" % [
        $tx.gasLimit, $tx.intrinsicGas(fork)])

    if fork >= FkCancun:
      if tx.payload.len > MAX_CALLDATA_SIZE:
        return err("invalid tx: payload len exceeds MAX_CALLDATA_SIZE. len=" &
          $tx.payload.len)

      if tx.accessList.len > MAX_ACCESS_LIST_SIZE:
        return err("invalid tx: access list len exceeds MAX_ACCESS_LIST_SIZE. len=" &
          $tx.accessList.len)

      for i, acl in tx.accessList:
        if acl.storageKeys.len > MAX_ACCESS_LIST_STORAGE_KEYS:
          return err("invalid tx: access list storage keys len exceeds MAX_ACCESS_LIST_STORAGE_KEYS. " &
            "index=$1, len=$2" % [$i, $acl.storageKeys.len])

    if tx.txType >= TxEip4844:
      if tx.to.isNone:
        return err("invalid tx: destination must be not empty")

      if tx.versionedHashes.len == 0:
        return err("invalid tx: there must be at least one blob")

      if tx.versionedHashes.len > MAX_BLOBS_PER_BLOCK:
        return err("invalid tx: versioned hashes len exceeds MAX_BLOBS_PER_BLOCK=" & $MAX_BLOBS_PER_BLOCK &
          ". get=" & $tx.versionedHashes.len)

      for i, bv in tx.versionedHashes:
        if bv.data[0] != VERSIONED_HASH_VERSION_KZG:
          return err("invalid tx: one of blobVersionedHash has invalid version. " &
            "get=$1, expect=$2" % [$bv.data[0].int, $VERSIONED_HASH_VERSION_KZG.int])

  except CatchableError as ex:
    return err(ex.msg)

  ok()

proc validateTransaction*(
    roDB:     ReadOnlyStateDB; ## Parent accounts environment for transaction
    tx:       Transaction;     ## tx to validate
    sender:   EthAddress;      ## tx.getSender or tx.ecRecover
    maxLimit: GasInt;          ## gasLimit from block header
    baseFee:  UInt256;         ## baseFee from block header
    excessBlobGas: uint64;    ## excessBlobGas from parent block header
    fork:     EVMFork): Result[void, string] =

  let res = validateTxBasic(tx, fork)
  if res.isErr:
    return res

  let
    balance = roDB.getBalance(sender)
    nonce = roDB.getNonce(sender)

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
  try:
    if maxLimit < tx.gasLimit:
      return err("invalid tx: block header gasLimit exceeded. maxLimit=$1, gasLimit=$2" % [
        $maxLimit, $tx.gasLimit])

    # ensure that the user was willing to at least pay the base fee
    if tx.maxFeePerGas < baseFee.truncate(GasInt):
      return err("invalid tx: maxFee is smaller than baseFee. maxFee=$1, baseFee=$2" % [
        $tx.maxFeePerGas, $baseFee])

    # the signer must be able to fully afford the transaction
    let gasCost = tx.gasCost()

    if balance < gasCost:
      return err("invalid tx: not enough cash for gas. avail=$1, require=$2" % [
        $balance, $gasCost])

    if balance - gasCost < tx.value:
      return err("invalid tx: not enough cash to send. avail=$1, availMinusGas=$2, require=$3" % [
        $balance, $(balance-gasCost), $tx.value])

    if tx.nonce != nonce:
      return err("invalid tx: account nonce mismatch. txNonce=$1, accNonce=$2" % [
        $tx.nonce, $nonce])

    if tx.nonce == high(uint64):
      return err("invalid tx: nonce at maximum")

    # EIP-3607 Reject transactions from senders with deployed code
    # The EIP spec claims this attack never happened before
    # Clients might choose to disable this rule for RPC calls like
    # `eth_call` and `eth_estimateGas`
    # EOA = Externally Owned Account
    let codeHash = roDB.getCodeHash(sender)
    if codeHash != EMPTY_CODE_HASH:
      return err("invalid tx: sender is not an EOA. sender=$1, codeHash=$2" % [
        sender.toHex, codeHash.data.toHex])

    if tx.txType >= TxEip4844:
      # ensure that the user was willing to at least pay the current data gasprice
      let blobGasPrice = getBlobBaseFee(excessBlobGas)
      if tx.maxFeePerBlobGas < blobGasPrice:
        return err("invalid tx: maxFeePerBlobGas smaller than blobGasPrice. " &
          "maxFeePerBlobGas=$1, blobGasPrice=$2" % [$tx.maxFeePerBlobGas, $blobGasPrice])

  except CatchableError as ex:
    return err(ex.msg)

  ok()

# ------------------------------------------------------------------------------
# Public functions, extracted from test_blockchain_json
# ------------------------------------------------------------------------------

proc validateHeaderAndKinship*(
    com: CommonRef;
    blk: EthBlock;
    parent: BlockHeader;
    checkSealOK: bool;
      ): Result[void, string]
      {.gcsafe, raises: [].} =
  template header: BlockHeader = blk.header

  if header.isGenesis:
    if header.extraData.len > 32:
      return err("BlockHeader.extraData larger than 32 bytes")
    return ok()

  ? com.validateHeader(blk, parent, checkSealOK)

  if blk.uncles.len > MAX_UNCLES:
    return err("Number of uncles exceed limit.")

  if com.consensus != ConsensusType.POS:
    ? com.validateUncles(header, blk.uncles, checkSealOK)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
