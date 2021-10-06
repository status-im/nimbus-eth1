# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/typetraits,
  stew/[objects, results],
  json_rpc/[rpcserver, errors],
  web3/[conversions, engine_api_types],
  ../sealer

# TODO move this to stew/objects
template newClone*[T: not ref](x: T): ref T =
  # TODO not nil in return type: https://github.com/nim-lang/Nim/issues/14146
  # TODO use only when x is a function call that returns a new instance!
  let res = new typeof(x) # TODO safe to do noinit here?
  res[] = x
  res

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
      raise (ref InvalidRequest)(code: UNKNOWN_PAYLOAD,
                                 msg: "Unknown payload")
    return payloads[int payloadId]

  server.rpc("engine_executePayload") do(payload: ExecutionPayload) -> ExecutePayloadResponse:
    discard

  server.rpc("engine_consensusValidated") do(data: BlockValidationResult):
    discard

  server.rpc("engine_forkchoiceUpdated") do(update: ForkChoiceUpdate):
    discard

