# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[options, typetraits],
  eth/common,
  ./web3_eth_conv,
  ./beacon_engine,
  ./execution_types,
  ./api_handler/api_utils,
  ./api_handler/api_getpayload,
  ./api_handler/api_getbodies,
  ./api_handler/api_exchangeconf,
  ./api_handler/api_newpayload,
  ./api_handler/api_forkchoice

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

{.push gcsafe, raises:[CatchableError].}

func validateVersionedHashed*(payload: ExecutionPayload,
                              expected: openArray[Web3Hash]): bool  =
  var versionedHashes: seq[common.Hash256]
  for x in payload.transactions:
    let tx = rlp.decode(distinctBase(x), Transaction)
    versionedHashes.add tx.versionedHashes
  for i, x in expected:
    if distinctBase(x) != versionedHashes[i].data:
      return false
  true

{.pop.}

export
  invalidStatus,
  getPayload,
  getPayloadV3,
  getPayloadBodiesByHash,
  getPayloadBodiesByRange,
  exchangeConf,
  newPayload,
  forkchoiceUpdated
