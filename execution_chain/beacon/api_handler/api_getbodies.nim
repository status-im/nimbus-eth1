# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/sequtils,
  eth/common/blocks,
  eth/common/block_access_lists,
  ../web3_eth_conv,
  ../beacon_engine,
  web3/execution_types,
  ./api_utils

from ../../db/payload_body_db import toPayloadBodyV1, toPayloadBodyV2
from beacon_chain/spec/engine_types import MAX_BODIES_REQUEST

{.push gcsafe, raises: [CatchableError].}

proc getPayloadBodiesByHash*(
    ben: BeaconEngineRef, hashes: seq[Hash32], withBlockAccessList: bool
): seq[Opt[(Block, Opt[BlockAccessListRef])]] =
  if hashes.len > MAX_BODIES_REQUEST:
    raise tooLargeRequest("request exceeds max allowed " & $MAX_BODIES_REQUEST)

  var list = newSeqOfCap[Opt[(Block, Opt[BlockAccessListRef])]](hashes.len)

  for h in hashes:
    var body = ben.chain.payloadBodyByHash(h, withBlockAccessList).valueOr:
      list.add Opt.none((Block, Opt[BlockAccessListRef]))
      continue
    list.add Opt.some(move(body))

  move(list)

# REMOVE WHEN DROPPING JSON-RPC
proc getPayloadBodiesByHashV1*(
    ben: BeaconEngineRef, hashes: seq[Hash32]
): seq[Opt[ExecutionPayloadBodyV1]] =
  ben.getPayloadBodiesByHash(hashes, withBlockAccessList = false).mapIt(
    if it.isSome: Opt.some(toPayloadBodyV1(it.get[0]))
    else: Opt.none(ExecutionPayloadBodyV1))

# REMOVE WHEN DROPPING JSON-RPC
proc getPayloadBodiesByHashV2*(
    ben: BeaconEngineRef, hashes: seq[Hash32]
): seq[Opt[ExecutionPayloadBodyV2]] =
  ben.getPayloadBodiesByHash(hashes, withBlockAccessList = true).mapIt(
    if it.isSome: Opt.some(toPayloadBodyV2(it.get[0], it.get[1]))
    else: Opt.none(ExecutionPayloadBodyV2))

proc getPayloadBodiesByRange*(
    ben: BeaconEngineRef, start: uint64, count: uint64, withBlockAccessList: bool
): seq[Opt[(Block, Opt[BlockAccessListRef])]] =
  if start == 0:
    raise invalidParams("start block should greater than zero")

  if count == 0:
    raise invalidParams("blocks count should greater than zero")

  if count > MAX_BODIES_REQUEST:
    raise tooLargeRequest("request exceeds max allowed " & $MAX_BODIES_REQUEST)

  var last = start + count - 1

  if start > ben.chain.latestNumber:
    # requested range beyond the latest known block.
    return

  if last > ben.chain.latestNumber:
    last = ben.chain.latestNumber

  let base = ben.chain.baseNumber
  var list = newSeqOfCap[Opt[(Block, Opt[BlockAccessListRef])]](last - start + 1)

  if start < base:
    # get bodies from database.
    for bn in start .. min(last, base):
      var body = ben.chain.payloadBodyByNumber(bn, withBlockAccessList).valueOr:
        list.add Opt.none((Block, Opt[BlockAccessListRef]))
        continue
      list.add Opt.some(move(body))

    # get bodies from cache in FC module.
    if last > base:
      ben.chain.payloadBodyInMemory(base, last, withBlockAccessList, list)
  else:
    ben.chain.payloadBodyInMemory(start, last, withBlockAccessList, list)

  move(list)

# REMOVE WHEN DROPPING JSON-RPC
proc getPayloadBodiesByRangeV1*(
    ben: BeaconEngineRef, start: uint64, count: uint64
): seq[Opt[ExecutionPayloadBodyV1]] =
  ben.getPayloadBodiesByRange(start, count, withBlockAccessList = false).mapIt(
    if it.isSome: Opt.some(toPayloadBodyV1(it.get[0]))
    else: Opt.none(ExecutionPayloadBodyV1))

# REMOVE WHEN DROPPING JSON-RPC
proc getPayloadBodiesByRangeV2*(
    ben: BeaconEngineRef, start: uint64, count: uint64
): seq[Opt[ExecutionPayloadBodyV2]] =
  ben.getPayloadBodiesByRange(start, count, withBlockAccessList = true).mapIt(
    if it.isSome: Opt.some(toPayloadBodyV2(it.get[0], it.get[1]))
    else: Opt.none(ExecutionPayloadBodyV2))