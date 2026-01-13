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
  ../beacon/api_handler,
  ../beacon/beacon_engine,
  ../version_info

from ../beacon/web3_eth_conv import Hash32

{.push raises: [].}

const supportedMethods: HashSet[string] =
  toHashSet([
    "engine_newPayloadV1",
    "engine_newPayloadV2",
    "engine_newPayloadV3",
    "engine_newPayloadV4",
    "engine_newPayloadV5",
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
    "engine_getPayloadBodiesByHashV1",
    "engine_getPayloadBodiesByHashV2",
    "engine_getPayloadBodiesByRangeV1",    
    "engine_getPayloadBodiesByRangeV2",
    "engine_getClientVersionV1",
    "engine_getBlobsV1",
    "engine_getBlobsV2",
    "engine_getBlobsV3"
  ])

# I'm trying to keep the handlers below very thin, and move the
# bodies up to the various procs above. Once we have multiple
# versions, they'll need to be able to share code.
proc setupEngineAPI*(engine: BeaconEngineRef, server: RpcServer) =
  server.rpc(EthJson):
    proc engine_exchangeCapabilities(methods: seq[string]): seq[string] =
      return methods.filterIt(supportedMethods.contains(it))

    proc engine_newPayloadV1(payload: ExecutionPayloadV1): PayloadStatusV1 =
      await engine.newPayload(Version.V1, payload.executionPayload)

    proc engine_newPayloadV2(payload: ExecutionPayload): PayloadStatusV1 =
      await engine.newPayload(Version.V2, payload)

    proc engine_newPayloadV3(payload: ExecutionPayload,
                                        expectedBlobVersionedHashes: Opt[seq[Hash32]],
                                        parentBeaconBlockRoot: Opt[Hash32]): PayloadStatusV1 =
      await engine.newPayload(Version.V3, payload, expectedBlobVersionedHashes, parentBeaconBlockRoot)

    proc engine_newPayloadV4(payload: ExecutionPayload,
                                        expectedBlobVersionedHashes: Opt[seq[Hash32]],
                                        parentBeaconBlockRoot: Opt[Hash32],
                                        executionRequests: Opt[seq[seq[byte]]]): PayloadStatusV1 =
      await engine.newPayload(Version.V4, payload,
        expectedBlobVersionedHashes, parentBeaconBlockRoot, executionRequests)

    proc engine_newPayloadV5(payload: ExecutionPayload,
                                        expectedBlobVersionedHashes: Opt[seq[Hash32]],
                                        parentBeaconBlockRoot: Opt[Hash32],
                                        executionRequests: Opt[seq[seq[byte]]]): PayloadStatusV1 =
      await engine.newPayload(Version.V5, payload,
        expectedBlobVersionedHashes, parentBeaconBlockRoot, executionRequests)

    proc engine_getPayloadV1(payloadId: Bytes8): ExecutionPayloadV1 =
      return engine.getPayload(Version.V1, payloadId).executionPayload.V1

    proc engine_getPayloadV2(payloadId: Bytes8): GetPayloadV2Response =
      return engine.getPayload(Version.V2, payloadId)

    proc engine_getPayloadV3(payloadId: Bytes8): GetPayloadV3Response =
      return engine.getPayloadV3(payloadId)

    proc engine_getPayloadV4(payloadId: Bytes8): GetPayloadV4Response =
      return engine.getPayloadV4(payloadId)

    proc engine_getPayloadV5(payloadId: Bytes8): GetPayloadV5Response =
      return engine.getPayloadV5(payloadId)

    proc engine_getPayloadV6(payloadId: Bytes8): GetPayloadV6Response =
      return engine.getPayloadV6(payloadId)

    proc engine_forkchoiceUpdatedV1(update: ForkchoiceStateV1,
                      attrs: Opt[PayloadAttributesV1]): ForkchoiceUpdatedResponse =
      await engine.forkchoiceUpdated(Version.V1, update, attrs.payloadAttributes)

    proc engine_forkchoiceUpdatedV2(update: ForkchoiceStateV1,
                      attrs: Opt[PayloadAttributes]): ForkchoiceUpdatedResponse =
      await engine.forkchoiceUpdated(Version.V2, update, attrs)

    proc engine_forkchoiceUpdatedV3(update: ForkchoiceStateV1,
                      attrs: Opt[PayloadAttributes]): ForkchoiceUpdatedResponse =
      await engine.forkchoiceUpdated(Version.V3, update, attrs)

    proc engine_getPayloadBodiesByHashV1(hashes: seq[Hash32]):
                                                seq[Opt[ExecutionPayloadBodyV1]] =
      return engine.getPayloadBodiesByHash(hashes)

  server.rpc("engine_forkchoiceUpdatedV4") do(update: ForkchoiceStateV1,
                    attrs: Opt[PayloadAttributes]) -> ForkchoiceUpdatedResponse:
    await engine.forkchoiceUpdated(Version.V4, update, attrs)

  server.rpc("engine_getPayloadBodiesByHashV1") do(hashes: seq[Hash32]) ->
                                               seq[Opt[ExecutionPayloadBodyV1]]:
    return engine.getPayloadBodiesByHashV1(hashes)

  server.rpc("engine_getPayloadBodiesByHashV2") do(hashes: seq[Hash32]) ->
                                               seq[Opt[ExecutionPayloadBodyV2]]:
    return engine.getPayloadBodiesByHashV2(hashes)

  server.rpc("engine_getPayloadBodiesByRangeV1") do(
      start: Quantity, count: Quantity) -> seq[Opt[ExecutionPayloadBodyV1]]:
    return engine.getPayloadBodiesByRangeV1(start.uint64, count.uint64)

  server.rpc("engine_getPayloadBodiesByRangeV2") do(
      start: Quantity, count: Quantity) -> seq[Opt[ExecutionPayloadBodyV2]]:
    return engine.getPayloadBodiesByRangeV2(start.uint64, count.uint64)

    proc engine_getBlobsV1(versionedHashes: seq[VersionedHash]):
                                          seq[Opt[BlobAndProofV1]] =
      return engine.getBlobsV1(versionedHashes)

    proc engine_getBlobsV2(versionedHashes: seq[VersionedHash]):
                                          Opt[seq[BlobAndProofV2]] =
      return engine.getBlobsV2(versionedHashes)

    proc engine_getBlobsV3(versionedHashes: seq[VersionedHash]):
                                          seq[Opt[BlobAndProofV2]] =
      return engine.getBlobsV3(versionedHashes)
