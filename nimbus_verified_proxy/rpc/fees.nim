# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  results,
  chronos,
  eth/common/eth_types_rlp,
  web3/[eth_api_types, eth_api],
  std/algorithm,
  ../../execution_chain/beacon/web3_eth_conv,
  ../types,
  ./blocks,
  ./transactions

func median(prices: var openArray[GasInt]): GasInt =
  if prices.len > 0:
    sort(prices)
    let middle = prices.len div 2
    if prices.len mod 2 == 0:
      # prevent overflow
      let addedAmt = prices[middle].uint64 + prices[middle - 1].uint64
      return (addedAmt div 2).GasInt
    else:
      return prices[middle]

  # default case
  return GasInt(0)

proc suggestGasPrice*(vp: VerifiedRpcProxy): Future[Result[GasInt, string]] {.async.} =
  const minGasPrice = 30_000_000_000.GasInt
  let
    blk = (await vp.getBlock(blockId("latest"), true)).valueOr:
      return err(error)
    txs = blk.transactions.toTransactions().valueOr:
      return err(error)

  var prices = newSeqOfCap[GasInt](64)
  for tx in txs:
    if tx.gasPrice > GasInt(0):
      prices.add(tx.gasPrice)

  ok(max(minGasPrice, median(prices)))

proc suggestMaxPriorityGasPrice*(
    vp: VerifiedRpcProxy
): Future[Result[GasInt, string]] {.async.} =
  let
    blk = (await vp.getBlock(blockId("latest"), true)).valueOr:
      return err(error)
    txs = blk.transactions.toTransactions().valueOr:
      return err(error)

  var prices = newSeqOfCap[GasInt](64)

  for tx in txs:
    if tx.maxPriorityFeePerGas > GasInt(0):
      prices.add(tx.maxPriorityFeePerGas)

  ok(median(prices))
