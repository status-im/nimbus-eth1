# nimbus-execution-client
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  json_rpc/client,
  ./conversions,
  ./execution_types

export
  conversions,
  execution_types

createRpcSigsFromNim(RpcClient, EthJson):
  # convenience apis
  proc engine_newPayloadV1(payload: ExecutionPayload): PayloadStatus
  proc engine_newPayloadV2(payload: ExecutionPayload): PayloadStatus
  proc engine_newPayloadV3(payload: ExecutionPayload,
    expectedBlobVersionedHashes: Opt[seq[VersionedHash]],
    parentBeaconBlockRoot: Opt[Hash32]): PayloadStatus
  proc engine_newPayloadV4(payload: ExecutionPayload,
    expectedBlobVersionedHashes: Opt[seq[VersionedHash]],
    parentBeaconBlockRoot: Opt[Hash32],
    executionRequests: Opt[seq[seq[byte]]]): PayloadStatus
  proc engine_newPayloadV5(payload: ExecutionPayload,
    expectedBlobVersionedHashes: Opt[seq[VersionedHash]],
    parentBeaconBlockRoot: Opt[Hash32],
    executionRequests: Opt[seq[seq[byte]]]): PayloadStatus
  proc engine_newPayloadV6(payload: ExecutionPayload,
    expectedBlobVersionedHashes: Opt[seq[VersionedHash]],
    parentBeaconBlockRoot: Opt[Hash32],
    executionRequests: Opt[seq[seq[byte]]],
    inclusionList: Opt[InclusionList]): PayloadStatus

  proc engine_newPayloadWithWitnessV4(payload: ExecutionPayload,
    expectedBlobVersionedHashes: Opt[seq[VersionedHash]],
    parentBeaconBlockRoot: Opt[Hash32],
    executionRequests: Opt[seq[seq[byte]]]): PayloadStatus
  proc engine_newPayloadWithWitnessV5(payload: ExecutionPayload,
    expectedBlobVersionedHashes: Opt[seq[VersionedHash]],
    parentBeaconBlockRoot: Opt[Hash32],
    executionRequests: Opt[seq[seq[byte]]]): PayloadStatus

  proc engine_forkchoiceUpdatedV1(forkchoiceState: ForkchoiceState, attributes: Opt[PayloadAttributes]): ForkchoiceUpdatedResponse
  proc engine_forkchoiceUpdatedV2(forkchoiceState: ForkchoiceState, attributes: Opt[PayloadAttributes]): ForkchoiceUpdatedResponse
  proc engine_forkchoiceUpdatedV3(forkchoiceState: ForkchoiceState, attributes: Opt[PayloadAttributes]): ForkchoiceUpdatedResponse
  proc engine_forkchoiceUpdatedV4(forkchoiceState: ForkchoiceState, attributes: Opt[PayloadAttributes], custodyColumns: Opt[FixedBytes[16]]): ForkchoiceUpdatedResponse
  proc engine_forkchoiceUpdatedV5(forkchoiceState: ForkchoiceState, attributes: Opt[PayloadAttributes], custodyColumns: Opt[FixedBytes[16]]): ForkchoiceUpdatedResponse
