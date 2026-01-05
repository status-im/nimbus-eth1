# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  ./types,
  ./blocks,
  ./transactions

func avgWoOverflow(a: uint64, b: uint64): uint64 =
  return a div 2 + b div 2 + ((a mod 2 + b mod 2) div 2)

func median(prices: var openArray[GasInt]): GasInt =
  if prices.len > 0:
    sort(prices)
    let middle = prices.len div 2
    if prices.len mod 2 == 0:
      # prevent overflow
      return avgWoOverflow(prices[middle], prices[middle - 1]).GasInt
    else:
      return prices[middle]

  # default case
  return GasInt(0)

proc suggestGasPrice*(
    engine: RpcVerificationEngine
): Future[EngineResult[GasInt]] {.async: (raises: [CancelledError]).} =
  const minGasPrice = 30_000_000_000.GasInt
  let
    blk = ?(await engine.getBlock(blockId("latest"), true))
    txs = ?blk.transactions.toTransactions()

  var prices = newSeqOfCap[GasInt](64)
  for tx in txs:
    if tx.gasPrice > GasInt(0):
      prices.add(tx.gasPrice)

  ok(max(minGasPrice, median(prices)))

proc suggestMaxPriorityGasPrice*(
    engine: RpcVerificationEngine
): Future[EngineResult[GasInt]] {.async: (raises: [CancelledError]).} =
  let
    blk = ?(await engine.getBlock(blockId("latest"), true))
    txs = ?blk.transactions.toTransactions()

  var prices = newSeqOfCap[GasInt](64)

  for tx in txs:
    if tx.maxPriorityFeePerGas > GasInt(0):
      prices.add(tx.maxPriorityFeePerGas)

  ok(median(prices))
