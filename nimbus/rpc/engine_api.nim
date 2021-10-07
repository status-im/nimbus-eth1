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
  ".."/p2p/chain/persist_blocks,
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

proc toBlockHeader(payload: ExecutionPayload): EthBlockHeader =
  discard payload.random # TODO: What should this be used for?

  EthBlockHeader(
    parentHash    : payload.parentHash.asEthHash,
    ommersHash    : EMPTY_UNCLE_HASH,
    coinbase      : EthAddress payload.coinbase,
    stateRoot     : payload.stateRoot.asEthHash,
    txRoot        : BLANK_ROOT_HASH, # EMPTY_UNCLE_HASH, # TODO This should be computed correctly
    receiptRoot   : payload.receiptRoot.asEthHash,
    bloom         : distinctBase(payload.logsBloom),
    difficulty    : default(DifficultyInt),
    blockNumber   : payload.blockNumber,
    gasLimit      : payload.gasLimit.unsafeQuantityToInt64,
    gasUsed       : payload.gasUsed.unsafeQuantityToInt64,
    timestamp     : fromUnix payload.timestamp.unsafeQuantityToInt64,
    extraData     : distinctBase payload.extraData,
    mixDigest     : default(Hash256),
    nonce         : default(BlockNonce),
    fee           : some payload.baseFeePerGas
  )

proc toBlockBody(payload: ExecutionPayload): BlockBody =
  # TODO the transactions from the payload have to be converted here
  discard payload.transactions

# TODO This code is missing from the spec and should be added
const
  INVALID_PAYLOAD = 10
  WE_ARE_SYNCING = 12

proc setupEngineAPI*(sealingEngine: SealingEngineRef, server: RpcServer) =

  var payloadsInstance = newClone(newSeq[ExecutionPayload]())
  template payloads: auto = payloadsInstance[]

  server.rpc("engine_preparePayload") do(payloadAttributes: PayloadAttributes) -> PreparePayloadResponse:
    # TODO we must take into consideration the payloadAttributes.parentHash value
    let response = PreparePayloadResponse(payloadId: Quantity payloads.len)

    var payload: ExecutionPayload
    let generatePayloadRes = sealingEngine.generateExecutionPayload(
      payloadAttributes,
      payload)
    if generatePayloadRes.isErr:
      raise newException(CatchableError, generatePayloadRes.error)

    payloads.add payload
    return response

  server.rpc("engine_getPayload") do(payloadId: Quantity) -> ExecutionPayload:
    if payloadId.uint64 > high(int).uint64 or
       int(payloadId) >= payloads.len:
      raise (ref InvalidRequest)(code: UNKNOWN_PAYLOAD, msg: "Unknown payload")
    return payloads[int payloadId]

  server.rpc("engine_executePayload") do(payload: ExecutionPayload) -> ExecutePayloadResponse:
    # TODO
    if payload.transactions.len > 0:
      # Give us a break, a block with transcations? instructions to execute?
      # Nah, we are syncing!
      raise (ref InvalidRequest)(code: WE_ARE_SYNCING, msg: "Sorry, syncing right now")

    let
      headers = [payload.toBlockHeader]
      bodies = [payload.toBlockBody]

    if rlpHash(headers[0]) != payload.blockHash.asEthHash:
      raise (ref InvalidRequest)(code: INVALID_PAYLOAD, msg: "Invalid payload block hash")

    if sealingEngine.chain.persistBlocks(headers, bodies) != ValidationResult.OK:
      raise (ref InvalidRequest)(code: INVALID_PAYLOAD, msg: "Invalid payload")

  server.rpc("engine_consensusValidated") do(data: BlockValidationResult):
    discard

  server.rpc("engine_forkchoiceUpdated") do(update: ForkChoiceUpdate):
    discard

