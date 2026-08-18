# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push gcsafe, raises: [].}

import
  web3/engine_api_types,
  eth/common/[blocks_rlp, block_access_lists_rlp],
  ../beacon/web3_eth_conv

func toPayloadBodyV1*(blk: Block): ExecutionPayloadBodyV1 =
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

func toPayloadBodyV2*(blk: Block, blockAccessList: Opt[BlockAccessListRef]): ExecutionPayloadBodyV2 =
  var wds: seq[WithdrawalV1]
  if blk.withdrawals.isSome:
    for w in blk.withdrawals.get:
      wds.add w3Withdrawal(w)

  ExecutionPayloadBodyV2(
    transactions: w3Txs(blk.transactions),
    # pre Shanghai block return null withdrawals
    # post Shanghai block return at least empty slice
    withdrawals: if blk.withdrawals.isSome:
                   Opt.some(wds)
                 else:
                   Opt.none(seq[WithdrawalV1]),
    blockAccessList: if blockAccessList.isSome():
                       Opt.some(blockAccessList.get()[].encode())
                     else:
                       Opt.none(seq[byte])
  )