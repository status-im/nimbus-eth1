# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits, times, strutils, sequtils],
  nimcrypto/[hash, sha2],
  web3/engine_api_types,
  json_rpc/errors,
  eth/[trie, rlp, common, common/eth_types, trie/db],
  stew/[results, byteutils],
  ../../constants,
  ./mergetypes

type Hash256 = eth_types.Hash256

proc computePayloadId*(headBlockHash: Hash256, params: PayloadAttributesV1 | PayloadAttributesV2): PayloadID =
  var dest: Hash256
  var ctx: sha256
  ctx.init()
  ctx.update(headBlockHash.data)
  ctx.update(toBytesBE distinctBase params.timestamp)
  ctx.update(distinctBase params.prevRandao)
  ctx.update(distinctBase params.suggestedFeeRecipient)
  # FIXME-Adam: Do we need to include the withdrawals in this calculation?
  # https://github.com/ethereum/go-ethereum/pull/25838#discussion_r1024340383
  # "The execution api specs define that this ID can be completely random. It
  # used to be derived from payload attributes in the past, but maybe it's
  # time to use a randomized ID to not break it with any changes to the
  # attributes?"
  ctx.finish dest.data
  ctx.clear()
  (distinctBase result)[0..7] = dest.data[0..7]

proc append*(w: var RlpWriter, q: Quantity) =
  w.append(uint64(q))

proc append*(w: var RlpWriter, a: Address) =
  w.append(distinctBase(a))

template unsafeQuantityToInt64(q: Quantity): int64 =
  int64 q

template asEthHash*(hash: engine_api_types.BlockHash): Hash256 =
  Hash256(data: distinctBase(hash))

proc calcRootHashRlp*(items: openArray[seq[byte]]): Hash256 =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in items:
    tr.put(rlp.encode(i), t)
  return tr.rootHash()

proc calcWithdrawalsRoot(withdrawals: seq[WithdrawalV1]): Hash256 =
  calcRootHashRlp(withdrawals.map(writer.encode))

func maybeWithdrawals*(payload: ExecutionPayloadV1 | ExecutionPayloadV2): Option[seq[WithdrawalV1]] =
  when payload is ExecutionPayloadV1:
    none[seq[WithdrawalV1]]()
  else:
    some(payload.withdrawals)

proc toBlockHeader*(payload: ExecutionPayloadV1 | ExecutionPayloadV2): EthBlockHeader =
  let transactions = seq[seq[byte]](payload.transactions)
  let txRoot = calcRootHashRlp(transactions)
  
  EthBlockHeader(
    parentHash     : payload.parentHash.asEthHash,
    ommersHash     : EMPTY_UNCLE_HASH,
    coinbase       : EthAddress payload.feeRecipient,
    stateRoot      : payload.stateRoot.asEthHash,
    txRoot         : txRoot,
    receiptRoot    : payload.receiptsRoot.asEthHash,
    bloom          : distinctBase(payload.logsBloom),
    difficulty     : default(DifficultyInt),
    blockNumber    : payload.blockNumber.distinctBase.u256,
    gasLimit       : payload.gasLimit.unsafeQuantityToInt64,
    gasUsed        : payload.gasUsed.unsafeQuantityToInt64,
    timestamp      : fromUnix payload.timestamp.unsafeQuantityToInt64,
    extraData      : bytes payload.extraData,
    mixDigest      : payload.prevRandao.asEthHash, # EIP-4399 redefine `mixDigest` -> `prevRandao`
    nonce          : default(BlockNonce),
    fee            : some payload.baseFeePerGas,
    withdrawalsRoot: payload.maybeWithdrawals.map(calcWithdrawalsRoot) # EIP-4895
  )

proc toWithdrawal*(w: WithdrawalV1): Withdrawal =
  Withdrawal(
    index: uint64(w.index),
    validatorIndex: uint64(w.validatorIndex),
    address: distinctBase(w.address),
    amount: uint64(w.amount)
  )

proc toWithdrawalV1*(w: Withdrawal): WithdrawalV1 =
  WithdrawalV1(
    index: Quantity(w.index),
    validatorIndex: Quantity(w.validatorIndex),
    address: Address(w.address),
    amount: Quantity(w.amount)
  )

proc toTypedTransaction*(tx: Transaction): TypedTransaction =
  TypedTransaction(rlp.encode(tx))

proc toBlockBody*(payload: ExecutionPayloadV1 | ExecutionPayloadV2): BlockBody =
  result.transactions.setLen(payload.transactions.len)
  for i, tx in payload.transactions:
    result.transactions[i] = rlp.decode(distinctBase tx, Transaction)
  when payload is ExecutionPayloadV2:
    let ws = payload.maybeWithdrawals
    result.withdrawals =
      if ws.isSome:
        some(ws.get.map(toWithdrawal))
      else:
        none[seq[Withdrawal]]()

proc `$`*(x: BlockHash): string =
  toHex(x)

template toValidHash*(x: Hash256): Option[BlockHash] =
  some(BlockHash(x.data))

proc validateBlockHash*(header: EthBlockHeader, gotHash: Hash256): Result[void, PayloadStatusV1] =
  let wantHash = header.blockHash
  if wantHash != gotHash:
    let status = PayloadStatusV1(
      # This used to say invalid_block_hash, but see here:
      # https://github.com/ethereum/execution-apis/blob/main/src/engine/shanghai.md#engine_newpayloadv2
      # "INVALID_BLOCK_HASH status value is supplanted by INVALID."
      status: PayloadExecutionStatus.invalid,
      validationError: some("blockhash mismatch, want $1, got $2" % [$wantHash, $gotHash])
    )
    return err(status)

  return ok()

proc simpleFCU*(status: PayloadExecutionStatus): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus: PayloadStatusV1(status: status))

proc simpleFCU*(status: PayloadExecutionStatus, msg: string): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(
    payloadStatus: PayloadStatusV1(
      status: status,
      validationError: some(msg)
    )
  )

proc invalidFCU*(hash: Hash256 = Hash256()): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus:
    PayloadStatusV1(
      status: PayloadExecutionStatus.invalid,
      latestValidHash: toValidHash(hash)
    )
  )

proc validFCU*(id: Option[PayloadID], validHash: Hash256): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(
    payloadStatus: PayloadStatusV1(
      status: PayloadExecutionStatus.valid,
      latestValidHash: toValidHash(validHash)
    ),
    payloadId: id
  )

proc invalidStatus*(validHash: Hash256, msg: string): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.invalid,
    latestValidHash: toValidHash(validHash),
    validationError: some(msg)
  )

proc invalidStatus*(validHash: Hash256 = Hash256()): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.invalid,
    latestValidHash: toValidHash(validHash)
  )

proc acceptedStatus*(validHash: Hash256): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.accepted,
    latestValidHash: toValidHash(validHash)
  )

proc acceptedStatus*(): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.accepted
  )

proc validStatus*(validHash: Hash256): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.valid,
    latestValidHash: toValidHash(validHash)
  )

proc invalidParams*(msg: string): ref InvalidRequest =
  (ref InvalidRequest)(
    code: engineApiInvalidParams,
    msg: msg
  )

proc unknownPayload*(msg: string): ref InvalidRequest =
  (ref InvalidRequest)(
    code: engineApiUnknownPayload,
    msg: msg
  )

proc invalidAttr*(msg: string): ref InvalidRequest =
  (ref InvalidRequest)(
    code: engineApiInvalidPayloadAttributes,
    msg: msg
  )
