# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  web3/ethtypes,
  web3/engine_api_types,
  ../../../nimbus/rpc/execution_types

proc engine_newPayloadV1(payload: ExecutionPayload): PayloadStatusV1
proc engine_newPayloadV2(payload: ExecutionPayload): PayloadStatusV1
proc engine_newPayloadV3(payload: ExecutionPayload, 
  expectedBlobVersionedHashes: Option[seq[VersionedHash]], 
  parentBeaconBlockRoot: Option[FixedBytes[32]]): PayloadStatusV1

proc engine_newPayloadV2(payload: ExecutionPayloadV1OrV2): PayloadStatusV1
proc engine_forkchoiceUpdatedV2(forkchoiceState: ForkchoiceStateV1, payloadAttributes: Option[PayloadAttributes]): ForkchoiceUpdatedResponse
proc engine_forkchoiceUpdatedV3(forkchoiceState: ForkchoiceStateV1, payloadAttributes: Option[PayloadAttributes]): ForkchoiceUpdatedResponse
