# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/sequtils,
  results,
  json_rpc/errors,
  web3/engine_api_types,
  ../../core/tx_pool,
  ../beacon_engine,
  ../../rpc/engine_ssz_types,
  ./api_utils

from ../../rpc/engine_ssz_conv import toWeb3

{.push gcsafe, raises:[ApplicationError].}

proc processGetBlobsV1(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  seq[Opt[engine_ssz_types.BlobAndProofV1]] =
  # https://github.com/ethereum/execution-apis/blob/c710097abda52b5a190d831eb8b1eddd3d28c603/src/engine/cancun.md#specification-3
  if versionedHashes.len > MAX_BLOBS_REQUEST:
    raise tooLargeRequest("the number of requested blobs is too large")

  # https://github.com/ethereum/execution-apis/blob/de87e24e0f2fbdbaee0fa36ab61b8ec25d3013d0/src/engine/osaka.md#cancun-api
  if ben.latestFork >= Osaka:
    raise unsupportedFork(
      "getBlobsV1 called after Osaka has been activated")

  versionedHashes.mapIt(ben.txPool.getBlobAndProofV1(it))

proc processGetBlobsV2(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  Opt[seq[engine_ssz_types.BlobAndProofV2]] =
  # https://github.com/ethereum/execution-apis/blob/de87e24e0f2fbdbaee0fa36ab61b8ec25d3013d0/src/engine/osaka.md#engine_getblobsv2
  if versionedHashes.len > MAX_BLOBS_REQUEST:
    raise tooLargeRequest("the number of requested blobs is too large")

  if ben.latestFork < Osaka:
    raise unsupportedFork(
      "getBlobsV2 called before Osaka has been activated")

  var list = newSeqOfCap[engine_ssz_types.BlobAndProofV2](versionedHashes.len)
  for v in versionedHashes:
    let blobAndProof = ben.txPool.getBlobAndProofV2(v).valueOr:
      return Opt.none(seq[engine_ssz_types.BlobAndProofV2])
    list.add blobAndProof

  ok(list)

proc processGetBlobsV3(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  seq[Opt[engine_ssz_types.BlobAndProofV2]] =
  # https://github.com/ethereum/execution-apis/pull/719
  if versionedHashes.len > MAX_BLOBS_REQUEST:
    raise tooLargeRequest("the number of requested blobs is too large")

  if ben.latestFork < Osaka:
    raise unsupportedFork(
      "getBlobsV3 called before Osaka has been activated")

  versionedHashes.mapIt(ben.txPool.getBlobAndProofV2(it))

proc getBlobsAndProofsV1*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]): BlobsV1Response =
  let entries = ben.processGetBlobsV1(versionedHashes).mapIt(
    block:
      if it.isSome: BlobV1Entry(available: true, contents: it.get)
      else: BlobV1Entry(available: false))
  BlobsV1Response(entries: List[BlobV1Entry, Limit MAX_BLOBS_REQUEST].init(entries))

proc getBlobsAndProofsV2*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]): Opt[BlobsV2Response] =
  let blobs = ben.processGetBlobsV2(versionedHashes).valueOr:
    return Opt.none(BlobsV2Response)
  let entries = blobs.mapIt(BlobV2Entry(available: true, contents: it))
  Opt.some(BlobsV2Response(entries: List[BlobV2Entry, Limit MAX_BLOBS_REQUEST].init(entries)))

proc getBlobsAndProofsV3*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]): BlobsV3Response =
  let entries = ben.processGetBlobsV3(versionedHashes).mapIt(
    block:
      if it.isSome: BlobV3Entry(available: true, contents: it.get)
      else: BlobV3Entry(available: false))
  BlobsV3Response(entries: List[BlobV3Entry, Limit MAX_BLOBS_REQUEST].init(entries))

# REMOVE WHEN DROPPING JSON-RPC
proc getBlobsV1*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  seq[Opt[engine_api_types.BlobAndProofV1]] =
  ben.processGetBlobsV1(versionedHashes).mapIt(
    if it.isSome: Opt.some(toWeb3(it.get))
    else: Opt.none(engine_api_types.BlobAndProofV1))

# REMOVE WHEN DROPPING JSON-RPC
proc getBlobsV2*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  Opt[seq[engine_api_types.BlobAndProofV2]] =
  let blobs = ben.processGetBlobsV2(versionedHashes).valueOr:
    return Opt.none(seq[engine_api_types.BlobAndProofV2])
  ok(blobs.mapIt(toWeb3(it)))

# REMOVE WHEN DROPPING JSON-RPC
proc getBlobsV3*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  seq[Opt[engine_api_types.BlobAndProofV2]] =
  ben.processGetBlobsV3(versionedHashes).mapIt(
    if it.isSome: Opt.some(toWeb3(it.get))
    else: Opt.none(engine_api_types.BlobAndProofV2))
