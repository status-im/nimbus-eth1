# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[options, typetraits],
  eth/common/blocks,
  ../web3_eth_conv,
  ../beacon_engine,
  web3/execution_types,
  ./api_utils

{.push gcsafe, raises:[CatchableError].}

const
  maxBodyRequest = 32

func toPayloadBody(blk: Block): ExecutionPayloadBodyV1 {.raises:[].}  =
  var wds: seq[WithdrawalV1]
  if blk.withdrawals.isSome:
    for w in blk.withdrawals.get:
      wds.add w3Withdrawal(w)

  ExecutionPayloadBodyV1(
    transactions: w3Txs(blk.transactions),
    # pre Shanghai block return null withdrawals
    # post Shanghai block return at least empty slice
    withdrawals: if blk.withdrawals.isSome:
                   Opt.some(wds)
                 else:
                   Opt.none(seq[WithdrawalV1])
  )

proc getPayloadBodiesByHash*(ben: BeaconEngineRef,
                             hashes: seq[Hash32]):
                               seq[Opt[ExecutionPayloadBodyV1]] =
  if hashes.len > maxBodyRequest:
    raise tooLargeRequest("request exceeds max allowed " & $maxBodyRequest)

  for h in hashes:
    let blk = ben.chain.blockByHash(h).valueOr:
      result.add Opt.none(ExecutionPayloadBodyV1)
      continue
    result.add Opt.some(toPayloadBody(blk))

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

  # get bodies from database
  for bn in start..min(last, ben.chain.baseNumber):
    let blk = ben.chain.blockByNumber(bn).valueOr:
      result.add Opt.none(ExecutionPayloadBodyV1)
      continue
    result.add Opt.some(blk.toPayloadBody)

  if last > ben.chain.baseNumber:
    let blocks = ben.chain.blockFromBaseTo(last)
    for i in countdown(blocks.len-1, 0):
      if blocks[i].header.number >= start:
        result.add Opt.some(toPayloadBody(blocks[i]))
