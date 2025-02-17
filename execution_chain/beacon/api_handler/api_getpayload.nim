# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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

  var bundle: ExecutionBundle
  if not ben.get(id, bundle):
    raise unknownPayload("Unknown bundle")

  let version = bundle.payload.version
  if version > expectedVersion:
    raise unsupportedFork("getPayload" & $expectedVersion &
      " expect payload" & $expectedVersion &
      " but get payload" & $version)
  if bundle.blobsBundle.isSome:
    raise unsupportedFork("getPayload" & $expectedVersion &
      " contains unsupported BlobsBundleV1")

  GetPayloadV2Response(
    executionPayload: bundle.payload.V1V2,
    blockValue: bundle.blockValue
  )

proc getPayloadV3*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV3Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  var bundle: ExecutionBundle
  if not ben.get(id, bundle):
    raise unknownPayload("Unknown bundle")

  let version = bundle.payload.version
  if version != Version.V3:
    raise unsupportedFork("getPayloadV3 expect payloadV3 but get payload" & $version)
  if bundle.blobsBundle.isNone:
    raise unsupportedFork("getPayloadV3 is missing BlobsBundleV1")

  let com = ben.com
  if not com.isCancunOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp is less than Cancun activation")

  GetPayloadV3Response(
    executionPayload: bundle.payload.V3,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.get,
    shouldOverrideBuilder: false
  )

proc getPayloadV4*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV4Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  var bundle: ExecutionBundle
  if not ben.get(id, bundle):
    raise unknownPayload("Unknown bundle")

  let version = bundle.payload.version
  if version != Version.V3:
    raise unsupportedFork("getPayloadV4 expect payloadV3 but get payload" & $version)
  if bundle.blobsBundle.isNone:
    raise unsupportedFork("getPayloadV4 is missing BlobsBundleV1")
  if bundle.executionRequests.isNone:
    raise unsupportedFork("getPayloadV4 is missing executionRequests")

  let com = ben.com
  if not com.isPragueOrLater(ethTime bundle.payload.timestamp):
    raise unsupportedFork("bundle timestamp is less than Prague activation")

  GetPayloadV4Response(
    executionPayload: bundle.payload.V3,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.get,
    shouldOverrideBuilder: false,
    executionRequests: bundle.executionRequests.get,
  )
