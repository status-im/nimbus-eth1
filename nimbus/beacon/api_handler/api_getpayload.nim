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
  eth/common,
  ../web3_eth_conv,
  ../beacon_engine,
  web3/execution_types,
  ./api_utils,
  chronicles

{.push gcsafe, raises:[CatchableError].}

proc getPayload*(ben: BeaconEngineRef,
                 expectedVersion: Version,
                 id: PayloadID): GetPayloadV2Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  var payloadGeneric: ExecutionPayload
  var blockValue: UInt256
  var blobsBundle: Opt[BlobsBundleV1]
  if not ben.get(id, blockValue, payloadGeneric, blobsBundle):
    raise unknownPayload("Unknown payload")

  let version = payloadGeneric.version
  if version > expectedVersion:
    raise unsupportedFork("getPayload" & $expectedVersion &
      " expect ExecutionPayload" & $expectedVersion &
      " but get ExecutionPayload" & $version)
  if blobsBundle.isSome:
    raise unsupportedFork("getPayload" & $expectedVersion &
      " contains unsupported BlobsBundleV1")

  GetPayloadV2Response(
    executionPayload: payloadGeneric.V1V2,
    blockValue: blockValue
  )

proc getPayloadV3*(ben: BeaconEngineRef, id: PayloadID): GetPayloadV3Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  var payloadGeneric: ExecutionPayload
  var blockValue: UInt256
  var blobsBundle: Opt[BlobsBundleV1]
  if not ben.get(id, blockValue, payloadGeneric, blobsBundle):
    raise unknownPayload("Unknown payload")

  let version = payloadGeneric.version
  if version != Version.V3:
    raise unsupportedFork("getPayloadV3 expect ExecutionPayloadV3 but get ExecutionPayload" & $version)
  if blobsBundle.isNone:
    raise unsupportedFork("getPayloadV3 is missing BlobsBundleV1")

  let payload = payloadGeneric.V3
  let com = ben.com
  if not com.isCancunOrLater(ethTime payload.timestamp):
    raise unsupportedFork("payload timestamp is less than Cancun activation")

  GetPayloadV3Response(
    executionPayload: payload,
    blockValue: blockValue,
    blobsBundle: blobsBundle.get,
    shouldOverrideBuilder: false
  )

proc getPayloadV4*(ben: BeaconEngineRef, id: PayloadID): GetPayloadV4Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  var payloadGeneric: ExecutionPayload
  var blockValue: UInt256
  var blobsBundle: Opt[BlobsBundleV1]
  if not ben.get(id, blockValue, payloadGeneric, blobsBundle):
    raise unknownPayload("Unknown payload")

  let version = payloadGeneric.version
  if version != Version.V4:
    raise unsupportedFork("getPayloadV4 expect ExecutionPayloadV4 but get ExecutionPayload" & $version)
  if blobsBundle.isNone:
    raise unsupportedFork("getPayloadV4 is missing BlobsBundleV1")

  let payload = payloadGeneric.V4
  let com = ben.com
  if not com.isPragueOrLater(ethTime payload.timestamp):
    raise unsupportedFork("payload timestamp is less than Prague activation")

  GetPayloadV4Response(
    executionPayload: payload,
    blockValue: blockValue,
    blobsBundle: blobsBundle.get,
    shouldOverrideBuilder: false
  )
