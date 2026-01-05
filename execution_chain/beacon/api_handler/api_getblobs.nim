# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  results,
  json_rpc/errors,
  web3/engine_api_types,
  ../../core/tx_pool,
  ../beacon_engine,
  ./api_utils

{.push gcsafe, raises:[ApplicationError].}

proc getBlobsV1*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  seq[Opt[BlobAndProofV1]] =
  # https://github.com/ethereum/execution-apis/blob/c710097abda52b5a190d831eb8b1eddd3d28c603/src/engine/cancun.md#specification-3
  if versionedHashes.len > 128:
    raise tooLargeRequest("the number of requested blobs is too large")

  # https://github.com/ethereum/execution-apis/blob/de87e24e0f2fbdbaee0fa36ab61b8ec25d3013d0/src/engine/osaka.md#cancun-api
  if ben.latestFork >= Osaka:
    raise unsupportedFork(
      "getBlobsV1 called after Osaka has been activated")

  for v in versionedHashes:
    result.add ben.txPool.getBlobAndProofV1(v)

proc getBlobsV2*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  Opt[seq[BlobAndProofV2]] =
  # https://github.com/ethereum/execution-apis/blob/de87e24e0f2fbdbaee0fa36ab61b8ec25d3013d0/src/engine/osaka.md#engine_getblobsv2
  if versionedHashes.len > 128:
    raise tooLargeRequest("the number of requested blobs is too large")

  if ben.latestFork < Osaka:
    raise unsupportedFork(
      "getBlobsV2 called before Osaka has been activated")

  var list = newSeqOfCap[BlobAndProofV2](versionedHashes.len)
  for v in versionedHashes:
    let blobAndProof = ben.txPool.getBlobAndProofV2(v).valueOr:
      return Opt.none(seq[BlobAndProofV2])
    list.add blobAndProof

  ok(list)

proc getBlobsV3*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  seq[Opt[BlobAndProofV2]] =
  # https://github.com/ethereum/execution-apis/pull/719
  if versionedHashes.len > 128:
    raise tooLargeRequest("the number of requested blobs is too large")

  if ben.latestFork < Osaka:
    raise unsupportedFork(
      "getBlobsV3 called before Osaka has been activated")

  var list = newSeqOfCap[Opt[BlobAndProofV2]](versionedHashes.len)
  for v in versionedHashes:
    list.add ben.txPool.getBlobAndProofV2(v)

  list
