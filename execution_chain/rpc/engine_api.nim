# Nimbus
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits, sequtils, sets],
  json_rpc/rpcserver,
  web3/[conversions, execution_types],
  metrics,
  chronos/timer,
  ../beacon/api_handler,
  ../beacon/beacon_engine,
  ../version_info

from ../beacon/web3_eth_conv import Hash32

{.push raises: [].}

declareCounter nec_engine_api_request_duration_ms,
  "Cumulative Engine API RPC request processing time in milliseconds",
  labels = ["method"]

declareCounter nec_engine_api_request_count,
  "Number of processed Engine API RPC requests",
  labels = ["method"]

template apiTiming(meth: static string, body: untyped): untyped =
  let start = Moment.now()
  let res = body
  nec_engine_api_request_duration_ms.inc(
    (Moment.now() - start).milliseconds(),
    labelValues = [meth])
  nec_engine_api_request_count.inc(1, labelValues = [meth])
  res

const supportedMethods: HashSet[string] =
  toHashSet([
    "engine_newPayloadV1",
    "engine_newPayloadV2",
    "engine_newPayloadV3",
    "engine_newPayloadV4",
    "engine_newPayloadV5",
    "engine_newPayloadV6",
    "engine_getPayloadV1",
    "engine_getPayloadV2",
    "engine_getPayloadV3",
    "engine_getPayloadV4",
    "engine_getPayloadV5",
    "engine_getPayloadV6",
    "engine_forkchoiceUpdatedV1",
    "engine_forkchoiceUpdatedV2",
    "engine_forkchoiceUpdatedV3",
    "engine_forkchoiceUpdatedV4",
    "engine_forkchoiceUpdatedV5",
    "engine_getPayloadBodiesByHashV1",
    "engine_getPayloadBodiesByHashV2",
    "engine_getPayloadBodiesByRangeV1",
    "engine_getPayloadBodiesByRangeV2",
    "engine_getClientVersionV1",
    "engine_getBlobsV1",
    "engine_getBlobsV2",
    "engine_getBlobsV3",
    "engine_getInclusionListV1",
  ])

# I'm trying to keep the handlers below very thin, and move the
# bodies up to the various procs above. Once we have multiple
# versions, they'll need to be able to share code.
proc setupEngineAPI*(engine: BeaconEngineRef, server: RpcServer) =
  server.rpc(EthJson):
    proc engine_exchangeCapabilities(methods: seq[string]): seq[string] =
      apiTiming("engine_exchangeCapabilities"):
        methods.filterIt(supportedMethods.contains(it))

    proc engine_newPayloadV1(payload: ExecutionPayloadV1): PayloadStatus {.async: (raises: [CancelledError, ApplicationError, RlpError]).} =
      apiTiming("engine_newPayloadV1"):
        await engine.newPayload(Version.V1, payload.executionPayload)

    proc engine_newPayloadV2(payload: ExecutionPayload): PayloadStatus {.async: (raises: [CancelledError, ApplicationError, RlpError]).} =
      apiTiming("engine_newPayloadV2"):
        await engine.newPayload(Version.V2, payload)

    proc engine_newPayloadV3(payload: ExecutionPayload,
                                        expectedBlobVersionedHashes: Opt[seq[Hash32]],
                                        parentBeaconBlockRoot: Opt[Hash32]): PayloadStatus {.async: (raises: [CancelledError, ApplicationError, RlpError]).} =
      apiTiming("engine_newPayloadV3"):
        await engine.newPayload(Version.V3, payload, expectedBlobVersionedHashes, parentBeaconBlockRoot)

    proc engine_newPayloadV4(payload: ExecutionPayload,
                                        expectedBlobVersionedHashes: Opt[seq[Hash32]],
                                        parentBeaconBlockRoot: Opt[Hash32],
                                        executionRequests: Opt[seq[seq[byte]]]): PayloadStatus {.async: (raises: [CancelledError, ApplicationError, RlpError]).} =
      apiTiming("engine_newPayloadV4"):
        await engine.newPayload(Version.V4, payload,
          expectedBlobVersionedHashes, parentBeaconBlockRoot, executionRequests)

    proc engine_newPayloadV5(payload: ExecutionPayload,
                                        expectedBlobVersionedHashes: Opt[seq[Hash32]],
                                        parentBeaconBlockRoot: Opt[Hash32],
                                        executionRequests: Opt[seq[seq[byte]]]): PayloadStatus {.async: (raises: [CancelledError, ApplicationError, RlpError]).} =
      apiTiming("engine_newPayloadV5"):
        await engine.newPayload(Version.V5, payload,
          expectedBlobVersionedHashes, parentBeaconBlockRoot, executionRequests)

    proc engine_newPayloadV6(payload: ExecutionPayload,
                                        expectedBlobVersionedHashes: Opt[seq[Hash32]],
                                        parentBeaconBlockRoot: Opt[Hash32],
                                        executionRequests: Opt[seq[seq[byte]]],
                                        inclusionList: Opt[InclusionList]): PayloadStatus {.async: (raises: [CancelledError, ApplicationError, RlpError]).} =
      apiTiming("engine_newPayloadV6"):
        await engine.newPayload(Version.V6, payload,
          expectedBlobVersionedHashes, parentBeaconBlockRoot, executionRequests, inclusionList)

    proc engine_getPayloadV1(payloadId: Bytes8): ExecutionPayloadV1 {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadV1"):
        engine.getPayload(Version.V1, payloadId).executionPayload.V1

    proc engine_getPayloadV2(payloadId: Bytes8): GetPayloadV2Response {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadV2"):
        engine.getPayload(Version.V2, payloadId)

    proc engine_getPayloadV3(payloadId: Bytes8): GetPayloadV3Response {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadV3"):
        engine.getPayloadV3(payloadId)

    proc engine_getPayloadV4(payloadId: Bytes8): GetPayloadV4Response {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadV4"):
        engine.getPayloadV4(payloadId)

    proc engine_getPayloadV5(payloadId: Bytes8): GetPayloadV5Response {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadV5"):
        engine.getPayloadV5(payloadId)

    proc engine_getPayloadV6(payloadId: Bytes8): GetPayloadV6Response {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadV6"):
        engine.getPayloadV6(payloadId)

    proc engine_forkchoiceUpdatedV1(update: ForkchoiceState,
                      attrs: Opt[PayloadAttributesV1]): ForkchoiceUpdatedResponse {.async: (raises: [CancelledError, ApplicationError]).} =
      apiTiming("engine_forkchoiceUpdatedV1"):
        await engine.forkchoiceUpdated(Version.V1, update, attrs.payloadAttributes)

    proc engine_forkchoiceUpdatedV2(update: ForkchoiceState,
                      attrs: Opt[PayloadAttributes]): ForkchoiceUpdatedResponse {.async: (raises: [CancelledError, ApplicationError]).} =
      apiTiming("engine_forkchoiceUpdatedV2"):
        await engine.forkchoiceUpdated(Version.V2, update, attrs)

    proc engine_forkchoiceUpdatedV3(update: ForkchoiceState,
                      attrs: Opt[PayloadAttributes]): ForkchoiceUpdatedResponse {.async: (raises: [CancelledError, ApplicationError]).} =
      apiTiming("engine_forkchoiceUpdatedV3"):
        await engine.forkchoiceUpdated(Version.V3, update, attrs)

    proc engine_forkchoiceUpdatedV4(update: ForkchoiceState,
                      attrs: Opt[PayloadAttributes]): ForkchoiceUpdatedResponse {.async: (raises: [CancelledError, ApplicationError]).} =
      apiTiming("engine_forkchoiceUpdatedV4"):
        await engine.forkchoiceUpdated(Version.V4, update, attrs)

    proc engine_forkchoiceUpdatedV5(update: ForkchoiceState,
                      attrs: Opt[PayloadAttributes]): ForkchoiceUpdatedResponse {.async: (raises: [CancelledError, ApplicationError]).} =
      apiTiming("engine_forkchoiceUpdatedV5"):
        await engine.forkchoiceUpdated(Version.V5, update, attrs)

    proc engine_getPayloadBodiesByHashV1(hashes: seq[Hash32]):
                                                seq[Opt[ExecutionPayloadBodyV1]] {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadBodiesByHashV1"):
        engine.getPayloadBodiesByHashV1(hashes)

    proc engine_getPayloadBodiesByHashV2(hashes: seq[Hash32]):
                                                seq[Opt[ExecutionPayloadBodyV2]] {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadBodiesByHashV2"):
        engine.getPayloadBodiesByHashV2(hashes)

    proc engine_getPayloadBodiesByRangeV1(
        start: Quantity, count: Quantity): seq[Opt[ExecutionPayloadBodyV1]] {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadBodiesByRangeV1"):
        engine.getPayloadBodiesByRangeV1(start.uint64, count.uint64)

    proc engine_getPayloadBodiesByRangeV2(
        start: Quantity, count: Quantity): seq[Opt[ExecutionPayloadBodyV2]] {.raises: [CatchableError].} =
      apiTiming("engine_getPayloadBodiesByRangeV2"):
        engine.getPayloadBodiesByRangeV2(start.uint64, count.uint64)

    proc engine_getClientVersionV1(version: ClientVersionV1):
                                          seq[ClientVersionV1] =
      # TODO: what should we do with the `version` parameter?
      apiTiming("engine_getClientVersionV1"):
        @[ClientVersionV1(
          code: "NB",
          name: NimbusName,
          version: NimbusVersion,
          commit: FixedBytes[4](GitRevisionBytes),
        )]

    proc engine_getBlobsV1(versionedHashes: seq[VersionedHash]):
                                          seq[Opt[BlobAndProofV1]] {.raises: [ApplicationError].} =
      apiTiming("engine_getBlobsV1"):
        engine.getBlobsV1(versionedHashes)

    proc engine_getBlobsV2(versionedHashes: seq[VersionedHash]):
                                          Opt[seq[BlobAndProofV2]] {.raises: [ApplicationError].} =
      apiTiming("engine_getBlobsV2"):
        engine.getBlobsV2(versionedHashes)

    proc engine_getBlobsV3(versionedHashes: seq[VersionedHash]):
                                          seq[Opt[BlobAndProofV2]] {.raises: [ApplicationError].} =
      apiTiming("engine_getBlobsV3"):
        engine.getBlobsV3(versionedHashes)

    proc engine_getInclusionListV1(parentHash: Hash32): InclusionList {.raises: [ApplicationError].} =
      apiTiming("engine_getInclusionListV1"):
        engine.getInclusionList(Version.V5, parentHash)
