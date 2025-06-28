# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  eth/common/blocks,
  ../web3_eth_conv,
  ../beacon_engine,
  web3/execution_types,
  ./api_utils

{.push gcsafe, raises:[CatchableError].}

const
  maxBodyRequest = 32

proc getPayloadBodiesByHash*(ben: BeaconEngineRef,
                             hashes: seq[Hash32]):
                               seq[Opt[ExecutionPayloadBodyV1]] =
  if hashes.len > maxBodyRequest:
    raise tooLargeRequest("request exceeds max allowed " & $maxBodyRequest)

  var list = newSeqOfCap[Opt[ExecutionPayloadBodyV1]](hashes.len)

  for h in hashes:
    var blk = ben.chain.payloadBodyV1ByHash(h).valueOr:
      list.add Opt.none(ExecutionPayloadBodyV1)
      continue
    list.add Opt.some(move(blk))

  move(list)

proc getPayloadBodiesByRange*(ben: BeaconEngineRef,
                              start: uint64, count: uint64):
                                seq[Opt[ExecutionPayloadBodyV1]] =
  if start == 0:
    raise invalidParams("start block should greater than zero")

  if count == 0:
    raise invalidParams("blocks count should greater than zero")

  if count > maxBodyRequest:
    raise tooLargeRequest("request exceeds max allowed " & $maxBodyRequest)

  var
    last = start+count-1

  if start > ben.chain.latestNumber:
    # requested range beyond the latest known block
    return

  if last > ben.chain.latestNumber:
    last = ben.chain.latestNumber

  var list = newSeqOfCap[Opt[ExecutionPayloadBodyV1]](last-start)

  # get bodies from database
  for bn in start..min(last, ben.chain.baseNumber):
    var blk = ben.chain.payloadBodyV1ByNumber(bn).valueOr:
      list.add Opt.none(ExecutionPayloadBodyV1)
      continue
    list.add Opt.some(move(blk))

  if last > ben.chain.baseNumber:
    ben.chain.payloadBodyV1FromBaseTo(last, list)

  move(list)
