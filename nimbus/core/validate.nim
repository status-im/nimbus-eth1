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
  std/[sequtils, sets, strformat],
  ../db/ledger,
  ../common/common,
  ../transaction/call_types,
  ../transaction,
  ../utils/utils,
  "."/[dao, eip4844, gaslimit, withdrawals],
  ./pow/[difficulty, header],
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
# Private validator functions
# ------------------------------------------------------------------------------

proc validateHeader(
    com: CommonRef;
    blk: Block;
    parentHeader: Header;
    checkSealOK: bool;
      ): Result[void,string] =
  template header: Header = blk.header
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
    return err("Header.extraData larger than 32 bytes")

  if header.gasUsed == 0 and 0 < blk.transactions.len:
    return err("zero gasUsed but transactions present");

  if header.gasUsed < 0 or header.gasUsed > header.gasLimit:
    return err("gasUsed should be non negative and smaller or equal gasLimit")

  if header.number != parentHeader.number + 1:
    return err("Blocks must be numbered consecutively")

  if header.timestamp <= parentHeader.timestamp:
    return err("timestamp must be strictly later than parent")

  if header.gasLimit > GAS_LIMIT_MAXIMUM:
    return err("gasLimit exceeds GAS_LIMIT_MAXIMUM")

  if com.daoForkSupport and inDAOExtraRange(header.number):
    if header.extraData != daoForkBlockExtraData:
      return err("header extra data should be marked DAO")

  if com.proofOfStake(header):
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

  ? com.validateWithdrawals(header, blk.withdrawals)
  ? com.validateEip4844Header(header, parentHeader, blk.transactions)
  ? com.validateGasLimitOrBaseFee(header, parentHeader)

  ok()

proc validateUncles(com: CommonRef; header: Header;
                    uncles: openArray[Header];
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
  var uncleSet = HashSet[Hash32]()
  for uncle in uncles:
    let uncleHash = uncle.blockHash
    if uncleHash in uncleSet:
      return err("Block contains duplicate uncles")
    else:
      uncleSet.incl uncleHash

  let
    chainDB = com.db
    recentAncestorHashes = ?chainDB.getAncestorsHashes(MAX_UNCLE_DEPTH + 1, header)
    recentUncleHashes = ?chainDB.getUncleHashes(recentAncestorHashes)
    blockHash = header.blockHash

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
    let parent = ?chainDB.getBlockHeader(uncle.parentHash)
    if uncle.timestamp <= parent.timestamp:
      return err("Uncle's parent must me older")

    let uncleParent = ?chainDB.getBlockHeader(uncle.parentHash)
    ? com.validateHeader(
      Block.init(uncle, BlockBody()), uncleParent, checkSealOK)

  ok()

# ------------------------------------------------------------------------------
# Public function, extracted from executor
# ------------------------------------------------------------------------------

proc validateLegacySignatureForm(tx: Transaction, fork: EVMFork): bool =
  var
    vMin = 27'u64
    vMax = 28'u64

  if tx.V >= EIP155_CHAIN_ID_OFFSET:
    let chainId = (tx.V - EIP155_CHAIN_ID_OFFSET) div 2
    vMin = 35 + (2 * chainId)
    vMax = vMin + 1

  var isValid = tx.R >= UInt256.one
  isValid = isValid and tx.S >= UInt256.one
  isValid = isValid and tx.V >= vMin
  isValid = isValid and tx.V <= vMax
  isValid = isValid and tx.S < SECPK1_N
  isValid = isValid and tx.R < SECPK1_N

  if fork >= FkHomestead:
    isValid = isValid and tx.S < SECPK1_N div 2

  isValid

proc validateEip2930SignatureForm(tx: Transaction): bool =
  var isValid = tx.V == 0'u64 or tx.V == 1'u64
  isValid = isValid and tx.S >= UInt256.one
  isValid = isValid and tx.S < SECPK1_N
  isValid = isValid and tx.R < SECPK1_N
  isValid

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

    if tx.txType == TxEip7702 and fork < FkPrague:
      return err("invalid tx: Eip7702 Tx type detected before Prague")

  if fork >= FkShanghai and tx.contractCreation and tx.payload.len > EIP3860_MAX_INITCODE_SIZE:
    return err("invalid tx: initcode size exceeds maximum")

  # The total must be the larger of the two
  if tx.maxFeePerGasNorm < tx.maxPriorityFeePerGasNorm:
    return err(&"invalid tx: maxFee is smaller than maPriorityFee. maxFee={tx.maxFeePerGas}, maxPriorityFee={tx.maxPriorityFeePerGasNorm}")

  if tx.gasLimit < tx.intrinsicGas(fork):
    return err(&"invalid tx: not enough gas to perform calculation. avail={tx.gasLimit}, require={tx.intrinsicGas(fork)}")

  if fork >= FkCancun:
    if tx.payload.len > MAX_CALLDATA_SIZE:
      return err(&"invalid tx: payload len exceeds MAX_CALLDATA_SIZE. len={tx.payload.len}")

    if tx.accessList.len > MAX_ACCESS_LIST_SIZE:
      return err("invalid tx: access list len exceeds MAX_ACCESS_LIST_SIZE. len=" &
        $tx.accessList.len)

    for i, acl in tx.accessList:
      if acl.storageKeys.len > MAX_ACCESS_LIST_STORAGE_KEYS:
        return err("invalid tx: access list storage keys len exceeds MAX_ACCESS_LIST_STORAGE_KEYS. " &
          &"index={i}, len={acl.storageKeys.len}")

  if tx.txType == TxLegacy:
    if not validateLegacySignatureForm(tx, fork):
      return err("invalid tx: invalid legacy signature form")
  else:
    if not validateEip2930SignatureForm(tx):
      return err("invalid tx: invalid post EIP-2930 signature form")

  if tx.txType == TxEip4844:
    if tx.to.isNone:
      return err("invalid tx: destination must be not empty")

    if tx.versionedHashes.len == 0:
      return err("invalid tx: there must be at least one blob")

    if tx.versionedHashes.len > MAX_BLOBS_PER_BLOCK:
      return err(&"invalid tx: versioned hashes len exceeds MAX_BLOBS_PER_BLOCK={MAX_BLOBS_PER_BLOCK}. get={tx.versionedHashes.len}")

    for i, bv in tx.versionedHashes:
      if bv.data[0] != VERSIONED_HASH_VERSION_KZG:
        return err("invalid tx: one of blobVersionedHash has invalid version. " &
          &"get={bv.data[0].int}, expect={VERSIONED_HASH_VERSION_KZG.int}")

  if tx.txType == TxEip7702:
    if tx.authorizationList.len == 0:
      return err("invalid tx: authorization list must not empty")

    const SECP256K1halfN = SECPK1_N div 2

    for auth in tx.authorizationList:
      if auth.v > 1'u64:
        return err("invalid tx: auth.v must be 0 or 1")

      if auth.s > SECP256K1halfN:
        return err("invalid tx: auth.s must be <= SECP256K1N/2")

  ok()

proc validateTransaction*(
    roDB:     ReadOnlyStateDB; ## Parent accounts environment for transaction
    tx:       Transaction;     ## tx to validate
    sender:   Address;         ## tx.recoverSender
    maxLimit: GasInt;          ## gasLimit from block header
    baseFee:  UInt256;         ## baseFee from block header
    excessBlobGas: uint64;     ## excessBlobGas from parent block header
    fork:     EVMFork): Result[void, string] =

  ? validateTxBasic(tx, fork)

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
  if maxLimit < tx.gasLimit:
    return err(&"invalid tx: block header gasLimit exceeded. maxLimit={maxLimit}, gasLimit={tx.gasLimit}")

  # ensure that the user was willing to at least pay the base fee
  if tx.maxFeePerGasNorm < baseFee.truncate(GasInt):
    return err(&"invalid tx: maxFee is smaller than baseFee. maxFee={tx.maxFeePerGas}, baseFee={baseFee}")

  # the signer must be able to fully afford the transaction
  let gasCost = tx.gasCost()

  if balance < gasCost:
    return err(&"invalid tx: not enough cash for gas. avail={balance}, require={gasCost}")

  if balance - gasCost < tx.value:
    return err(&"invalid tx: not enough cash to send. avail={balance}, availMinusGas={balance-gasCost}, require={tx.value}")

  if tx.nonce != nonce:
    return err(&"invalid tx: account nonce mismatch. txNonce={tx.nonce}, accNonce={nonce}")

  if tx.nonce == high(uint64):
    return err(&"invalid tx: nonce at maximum")

  # EIP-3607 Reject transactions from senders with deployed code
  # The EIP spec claims this attack never happened before
  # Clients might choose to disable this rule for RPC calls like
  # `eth_call` and `eth_estimateGas`
  # EOA = Externally Owned Account
  let codeHash = roDB.getCodeHash(sender)
  if codeHash != EMPTY_CODE_HASH:
    return err(&"invalid tx: sender is not an EOA. sender={sender.toHex}, codeHash={codeHash.data.toHex}")

  if tx.txType == TxEip4844:
    # ensure that the user was willing to at least pay the current data gasprice
    let blobGasPrice = getBlobBaseFee(excessBlobGas)
    if tx.maxFeePerBlobGas < blobGasPrice:
      return err("invalid tx: maxFeePerBlobGas smaller than blobGasPrice. " &
        &"maxFeePerBlobGas={tx.maxFeePerBlobGas}, blobGasPrice={blobGasPrice}")

  ok()

# ------------------------------------------------------------------------------
# Public functions, extracted from test_blockchain_json
# ------------------------------------------------------------------------------

proc validateHeaderAndKinship*(
    com: CommonRef;
    blk: Block;
    parent: Header;
    checkSealOK: bool;
      ): Result[void, string]
      {.gcsafe, raises: [].} =
  template header: Header = blk.header

  if header.isGenesis:
    if header.extraData.len > 32:
      return err("Header.extraData larger than 32 bytes")
    return ok()

  ? com.validateHeader(blk, parent, checkSealOK)

  if blk.uncles.len > MAX_UNCLES:
    return err("Number of uncles exceed limit.")

  if not com.proofOfStake(header):
    ? com.validateUncles(header, blk.uncles, checkSealOK)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
