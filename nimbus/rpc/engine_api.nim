# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits, times],
  stew/[objects, results],
  json_rpc/[rpcserver, errors],
  web3/[conversions, engine_api_types],
  eth/[trie, rlp, common, trie/db],
  ".."/db/db_chain,
  ".."/p2p/chain/[chain_desc, persist_blocks],
  ".."/[sealer, utils, constants]

import eth/common/eth_types except BlockHeader
type EthBlockHeader = eth_types.BlockHeader

# TODO move this to stew/objects
template newClone*[T: not ref](x: T): ref T =
  # TODO not nil in return type: https://github.com/nim-lang/Nim/issues/14146
  # TODO use only when x is a function call that returns a new instance!
  let res = new typeof(x) # TODO safe to do noinit here?
  res[] = x
  res

template asEthHash*(hash: engine_api_types.BlockHash): Hash256 =
  Hash256(data: distinctBase(hash))

template unsafeQuantityToInt64(q: Quantity): int64 =
  int64 q

proc calcRootHashRlp*(items: openArray[seq[byte]]): Hash256 =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in items:
    tr.put(rlp.encode(i), t)
  return tr.rootHash()

proc toBlockHeader(payload: ExecutionPayloadV1): eth_types.BlockHeader =
  discard payload.prevRandao # TODO: What should this be used for?

  let transactions = seq[seq[byte]](payload.transactions)
  let txRoot = calcRootHashRlp(transactions)

  EthBlockHeader(
    parentHash    : payload.parentHash.asEthHash,
    ommersHash    : EMPTY_UNCLE_HASH,
    coinbase      : EthAddress payload.feeRecipient,
    stateRoot     : payload.stateRoot.asEthHash,
    txRoot        : txRoot,
    receiptRoot   : payload.receiptsRoot.asEthHash,
    bloom         : distinctBase(payload.logsBloom),
    difficulty    : default(DifficultyInt),
    blockNumber   : payload.blockNumber.distinctBase.u256,
    gasLimit      : payload.gasLimit.unsafeQuantityToInt64,
    gasUsed       : payload.gasUsed.unsafeQuantityToInt64,
    timestamp     : fromUnix payload.timestamp.unsafeQuantityToInt64,
    extraData     : distinctBase payload.extraData,
    mixDigest     : default(Hash256),
    nonce         : default(BlockNonce),
    fee           : some payload.baseFeePerGas
  )

proc toBlockBody(payload: ExecutionPayloadV1): BlockBody =
  # TODO the transactions from the payload have to be converted here
  discard payload.transactions

proc setupEngineAPI*(
    sealingEngine: SealingEngineRef,
    server: RpcServer) =

  var payloadsInstance = newClone(newSeq[ExecutionPayloadV1]())
  template payloads: auto = payloadsInstance[]

  # https://github.com/ethereum/execution-apis/blob/v1.0.0-alpha.5/src/engine/specification.md#engine_getpayloadv1
  server.rpc("engine_getPayloadV1") do(payloadIdBytes: FixedBytes[8]) -> ExecutionPayloadV1:
    let payloadId = uint64.fromBytesBE(distinctBase payloadIdBytes)
    if payloadId > payloads.len.uint64:
      raise (ref InvalidRequest)(code: engineApiUnknownPayload, msg: "Unknown payload")
    return payloads[int payloadId]

  # https://github.com/ethereum/execution-apis/blob/v1.0.0-alpha.5/src/engine/specification.md#engine_executepayloadv1
  #[server.rpc("engine_executePayloadV1") do(payload: ExecutionPayloadV1) -> ExecutePayloadResponse:
    # TODO
    if payload.transactions.len > 0:
      # Give us a break, a block with transcations? instructions to execute?
      # Nah, we are syncing!
      return ExecutePayloadResponse(status: PayloadExecutionStatus.syncing)

    # TODO check whether we are syncing

    let
      headers = [payload.toBlockHeader]
      bodies = [payload.toBlockBody]

    if rlpHash(headers[0]) != payload.blockHash.asEthHash:
      return ExecutePayloadResponse(status: PayloadExecutionStatus.invalid,
                                    validationError: some "payload root doesn't match its contents")

    if sealingEngine.chain.persistBlocks(headers, bodies) != ValidationResult.OK:
      # TODO Provide validationError and latestValidHash
      return ExecutePayloadResponse(status: PayloadExecutionStatus.invalid)

    return ExecutePayloadResponse(status: PayloadExecutionStatus.valid,
                                  latestValidHash: some payload.blockHash)

  # https://github.com/ethereum/execution-apis/blob/v1.0.0-alpha.5/src/engine/specification.md#engine_forkchoiceupdatedv1
  server.rpc("engine_forkchoiceUpdatedV1") do(
      update: ForkchoiceStateV1,
      payloadAttributes: Option[PayloadAttributesV1]) -> ForkchoiceUpdatedResponse:
    let
      db = sealingEngine.chain.db
      newHead = update.headBlockHash.asEthHash

    # TODO Use the finalized block information to prune any alterantive
    #      histories that are no longer relevant
    discard update.finalizedBlockHash

    # TODO Check whether we are syncing

    if not db.setHead(newHead):
      return ForkchoiceUpdatedResponse(status: ForkchoiceUpdatedStatus.syncing)

    if payloadAttributes.isSome:
      let payloadId = uint64 payloads.len

      var payload: ExecutionPayloadV1
      let generatePayloadRes = sealingEngine.generateExecutionPayload(
        payloadAttributes.get,
        payload)
      if generatePayloadRes.isErr:
        raise newException(CatchableError, generatePayloadRes.error)

      payloads.add payload

      return ForkchoiceUpdatedResponse(status: ForkchoiceUpdatedStatus.success,
                                       payloadId: some payloadId.toBytesBE.PayloadID)
    else:
      return ForkchoiceUpdatedResponse(status: ForkchoiceUpdatedStatus.success)]#
