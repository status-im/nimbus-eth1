# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits],
  ../web3_eth_conv,
  ../beacon_engine,
  web3/execution_types,
  ./api_utils,
  chronicles

{.push gcsafe, raises:[CatchableError].}

proc getPayload*(ben: BeaconEngineRef,
                 expectedVersion: Version,
                 id: Bytes8): GetPayloadV2Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let bundle = ben.getPayloadBundle(id).valueOr:
    raise unknownPayload("Unknown bundle")

  let
    version = bundle.payload.version
    com = ben.com

  if version > expectedVersion:
    raise unsupportedFork("getPayload" & $expectedVersion &
      " expect payload" & $expectedVersion &
      " but get payload" & $version)
  if bundle.blobsBundle.isNil.not:
    raise unsupportedFork("getPayload" & $expectedVersion &
      " contains unsupported BlobsBundleV1")

  if com.isOsakaOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp greater than Osaka must use getPayloadV5")

  GetPayloadV2Response(
    executionPayload: bundle.payload.V1V2,
    blockValue: bundle.blockValue
  )

proc getPayloadV3*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV3Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let bundle = ben.getPayloadBundle(id).valueOr:
    raise unknownPayload("Unknown bundle")

  let version = bundle.payload.version
  if version != Version.V3:
    raise unsupportedFork("getPayloadV3 expect payloadV3 but get payload" & $version)
  if bundle.blobsBundle.isNil:
    raise unsupportedFork("getPayloadV3 is missing BlobsBundleV1")

  let com = ben.com
  if not com.isCancunOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp is less than Cancun activation")

  if com.isOsakaOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp greater than Osaka must use getPayloadV5")

  GetPayloadV3Response(
    executionPayload: bundle.payload.V3,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.V1,
    shouldOverrideBuilder: false
  )

proc getPayloadV4*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV4Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let bundle = ben.getPayloadBundle(id).valueOr:
    raise unknownPayload("Unknown bundle")

  let version = bundle.payload.version
  if version != Version.V3:
    raise unsupportedFork("getPayloadV4 expect payloadV3 but get payload" & $version)
  if bundle.blobsBundle.isNil:
    raise unsupportedFork("getPayloadV4 is missing BlobsBundleV1")
  if bundle.executionRequests.isNone:
    raise unsupportedFork("getPayloadV4 is missing executionRequests")

  let com = ben.com
  if not com.isPragueOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp is less than Prague activation")

  if com.isOsakaOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp greater than Osaka must use getPayloadV5")

  GetPayloadV4Response(
    executionPayload: bundle.payload.V3,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.V1,
    shouldOverrideBuilder: false,
    executionRequests: bundle.executionRequests.get,
  )

proc getPayloadV5*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV5Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let bundle = ben.getPayloadBundle(id).valueOr:
    raise unknownPayload("Unknown bundle")

  let version = bundle.payload.version
  if version != Version.V3:
    raise unsupportedFork("getPayloadV5 expect ExecutionPayloadV3 but got ExecutionPayload" & $version)
  if bundle.blobsBundle.isNil:
    raise unsupportedFork("getPayloadV5 is missing BlobsBundleV2")
  if bundle.executionRequests.isNone:
    raise unsupportedFork("getPayloadV5 is missing executionRequests")

  let com = ben.com
  if not com.isOsakaOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp is less than Osaka activation")

  if com.isAmsterdamOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp greater than Amsterdam must use getPayloadV6")

  GetPayloadV5Response(
    executionPayload: bundle.payload.V3,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.V2,
    shouldOverrideBuilder: false,
    executionRequests: bundle.executionRequests.get,
  )

proc getPayloadV6*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV6Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let bundle = ben.getPayloadBundle(id).valueOr:
    raise unknownPayload("Unknown bundle")

  let version = bundle.payload.version
  if version != Version.V4:
    raise unsupportedFork("getPayloadV6 expect ExecutionPayloadV4 but got ExecutionPayload" & $version)
  if bundle.blobsBundle.isNil:
    raise unsupportedFork("getPayloadV6 is missing BlobsBundleV2")
  if bundle.executionRequests.isNone:
    raise unsupportedFork("getPayloadV6 is missing executionRequests")

  let com = ben.com
  if not com.isAmsterdamOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp is less than Amsterdam activation")

  GetPayloadV6Response(
    executionPayload: bundle.payload.V4,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.V2,
    shouldOverrideBuilder: false,
    executionRequests: bundle.executionRequests.get,
  )
