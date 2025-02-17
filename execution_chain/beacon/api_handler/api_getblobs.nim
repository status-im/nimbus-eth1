# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
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

{.push gcsafe, raises:[InvalidRequest].}

proc getBlobsV1*(ben: BeaconEngineRef,
               versionedHashes: openArray[VersionedHash]):
                  seq[Opt[BlobAndProofV1]] =
  # https://github.com/ethereum/execution-apis/blob/c710097abda52b5a190d831eb8b1eddd3d28c603/src/engine/cancun.md#specification-3
  if versionedHashes.len > 128:
    raise tooLargeRequest("the number of requested blobs is too large")

  for v in versionedHashes:
    result.add ben.txPool.getBlobAndProofV1(v)
