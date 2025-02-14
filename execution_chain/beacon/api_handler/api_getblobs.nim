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
  web3/engine_api_types,
  ../../core/tx_pool,
  ../beacon_engine,
  ./api_utils

{.push gcsafe, raises:[CatchableError].}

proc getBlobs*(ben: BeaconEngineRef,
               versionedHashes: openArray[Hash32]):
                  seq[Opt[BlobAndProofV1]] =
  if versionedHashes.len > 128:
    raise tooLargeRequest("getBlobs request too much blobs")

  for v in versionedHashes:
    result.add ben.txPool.getBlobAndProof(v)
