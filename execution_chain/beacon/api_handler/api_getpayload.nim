# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push gcsafe, raises:[CatchableError].}

import
  std/[typetraits],
  ../web3_eth_conv,
  ../beacon_engine,
  ../payload_conv,
  web3/execution_types,
  ./api_utils,
  chronicles

from beacon_chain/spec/engine_types import EngineFork

# REMOVE WHEN DROPPING JSON-RPC
func versionToFork(version: Version): EngineFork =
  if version == Version.V1: EngineFork.Paris else: EngineFork.Shanghai

func payloadShapeFork(header: Header): EngineFork =
  if header.blockAccessListHash.isSome or header.slotNumber.isSome:
    EngineFork.Amsterdam
  elif header.blobGasUsed.isSome or header.excessBlobGas.isSome:
    EngineFork.Cancun
  elif header.withdrawalsRoot.isSome:
    EngineFork.Shanghai
  else:
    EngineFork.Paris

proc fetchPayload(ben: BeaconEngineRef, fork: EngineFork, id: Bytes8): ExecutionBundle =
  let bundle = ben.getPayloadBundle(id).valueOr:
    raise unknownPayload("Unknown bundle")

  let
    shapeFork = payloadShapeFork(bundle.blk.header)
    com = ben.com
    timestamp = bundle.blk.header.timestamp

  case fork
  of EngineFork.Paris, EngineFork.Shanghai:
    if shapeFork > fork:
      raise unsupportedFork($fork & " expects " & $fork &
        "-shaped ExecutionPayload but built payload has " & $shapeFork & "-shaped payload")
    if bundle.blobsBundle.isNil.not:
      raise unsupportedFork($fork & " payload must not contain a blobs bundle")
    if com.isOsakaOrLater(timestamp):
      raise unsupportedFork(
        "bundle timestamp is at or past Osaka activation, requires Osaka fork or later")
  of EngineFork.Cancun:
    if shapeFork != EngineFork.Cancun:
      raise unsupportedFork($fork & " expects Cancun-shaped ExecutionPayload but built payload " &
        "has " & $shapeFork & "-shaped payload")
    if bundle.blobsBundle.isNil:
      raise unsupportedFork($fork & " payload is missing a BlobsBundleV1")
    if not com.isCancunOrLater(timestamp):
      raise unsupportedFork("bundle timestamp is less than Cancun activation")
    if com.isOsakaOrLater(timestamp):
      raise unsupportedFork(
        "bundle timestamp is at or past Osaka activation, requires Osaka fork or later")
  of EngineFork.Prague:
    if shapeFork != EngineFork.Cancun:
      raise unsupportedFork($fork & " expects Cancun-shaped ExecutionPayload but built payload " &
        "has " & $shapeFork & "-shaped payload")
    if bundle.blobsBundle.isNil:
      raise unsupportedFork($fork & " payload is missing a BlobsBundleV1")
    if bundle.executionRequests.isNone:
      raise unsupportedFork($fork & " payload is missing executionRequests")
    if not com.isPragueOrLater(timestamp):
      raise unsupportedFork("bundle timestamp is less than Prague activation")
    if com.isOsakaOrLater(timestamp):
      raise unsupportedFork(
        "bundle timestamp is at or past Osaka activation, requires Osaka fork or later")
  of EngineFork.Osaka:
    if shapeFork != EngineFork.Cancun:
      raise unsupportedFork($fork & " expects Cancun-shaped ExecutionPayload but built payload " &
        "has " & $shapeFork & "-shaped payload")
    if bundle.blobsBundle.isNil:
      raise unsupportedFork($fork & " payload is missing a BlobsBundleV2")
    if bundle.executionRequests.isNone:
      raise unsupportedFork($fork & " payload is missing executionRequests")
    if not com.isOsakaOrLater(timestamp):
      raise unsupportedFork("bundle timestamp is less than Osaka activation")
    if com.isAmsterdamOrLater(timestamp):
      raise unsupportedFork(
        "bundle timestamp is at or past Amsterdam activation, requires Amsterdam fork or later")
  of EngineFork.Amsterdam:
    if shapeFork != EngineFork.Amsterdam:
      raise unsupportedFork($fork & " expects Amsterdam-shaped ExecutionPayload but built " &
        "payload has " & $shapeFork & "-shaped payload")
    if bundle.blobsBundle.isNil:
      raise unsupportedFork($fork & " payload is missing a BlobsBundleV2")
    if bundle.executionRequests.isNone:
      raise unsupportedFork($fork & " payload is missing executionRequests")
    if not com.isAmsterdamOrLater(timestamp):
      raise unsupportedFork("bundle timestamp is less than Amsterdam activation")

  bundle

proc getPayload*(ben: BeaconEngineRef, fork: EngineFork, id: Bytes8): ExecutionBundle =
  ben.fetchPayload(fork, id)

# REMOVE WHEN DROPPING JSON-RPC
proc getPayload*(ben: BeaconEngineRef,
                 expectedVersion: Version,
                 id: Bytes8): GetPayloadV2Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let fork = versionToFork(expectedVersion)
  let bundle = ben.fetchPayload(fork, id)
  let payload = executionPayload(bundle.blk, bundle.blockAccessList)
  GetPayloadV2Response(
    executionPayload: payload.V1V2,
    blockValue: bundle.blockValue
  )

# REMOVE WHEN DROPPING JSON-RPC
proc getPayloadV3*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV3Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let bundle = ben.fetchPayload(EngineFork.Cancun, id)
  let payload = executionPayload(bundle.blk, bundle.blockAccessList)
  GetPayloadV3Response(
    executionPayload: payload.V3,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.V1,
    shouldOverrideBuilder: false
  )

# REMOVE WHEN DROPPING JSON-RPC
proc getPayloadV4*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV4Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let bundle = ben.fetchPayload(EngineFork.Prague, id)
  let payload = executionPayload(bundle.blk, bundle.blockAccessList)
  GetPayloadV4Response(
    executionPayload: payload.V3,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.V1,
    shouldOverrideBuilder: false,
    executionRequests: bundle.executionRequests.get,
  )

# REMOVE WHEN DROPPING JSON-RPC
proc getPayloadV5*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV5Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let bundle = ben.fetchPayload(EngineFork.Osaka, id)
  let payload = executionPayload(bundle.blk, bundle.blockAccessList)
  GetPayloadV5Response(
    executionPayload: payload.V3,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.V2,
    shouldOverrideBuilder: false,
    executionRequests: bundle.executionRequests.get,
  )

# REMOVE WHEN DROPPING JSON-RPC
proc getPayloadV6*(ben: BeaconEngineRef, id: Bytes8): GetPayloadV6Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  let bundle = ben.fetchPayload(EngineFork.Amsterdam, id)
  let payload = executionPayload(bundle.blk, bundle.blockAccessList)
  GetPayloadV6Response(
    executionPayload: payload.V4,
    blockValue: bundle.blockValue,
    blobsBundle: bundle.blobsBundle.V2,
    shouldOverrideBuilder: false,
    executionRequests: bundle.executionRequests.get,
  )
