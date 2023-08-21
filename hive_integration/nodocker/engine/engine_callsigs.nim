import
  web3/ethtypes,
  web3/engine_api_types,
  ../../../nimbus/rpc/execution_types

proc engine_newPayloadV2(payload: ExecutionPayloadV1OrV2): PayloadStatusV1
proc engine_forkchoiceUpdatedV2(forkchoiceState: ForkchoiceStateV1, payloadAttributes: Option[PayloadAttributes]): ForkchoiceUpdatedResponse
proc engine_forkchoiceUpdatedV3(forkchoiceState: ForkchoiceStateV1, payloadAttributes: Option[PayloadAttributes]): ForkchoiceUpdatedResponse
