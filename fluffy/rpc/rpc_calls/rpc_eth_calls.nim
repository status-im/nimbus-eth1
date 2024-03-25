# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/json,
  json_serialization/stew/results,
  json_rpc/[client, jsonmarshal],
  web3/conversions,
  web3/eth_api_types

export eth_api_types

createRpcSigsFromNim(RpcClient):
  proc eth_chainId(): Quantity
  proc eth_getBlockByHash(data: BlockHash, fullTransactions: bool): Opt[BlockObject]
  proc eth_getBlockByNumber(
    blockId: BlockIdentifier, fullTransactions: bool
  ): Opt[BlockObject]

  proc eth_getBlockTransactionCountByHash(data: BlockHash): Quantity
  proc eth_getTransactionReceipt(data: TxHash): Opt[ReceiptObject]
  proc eth_getLogs(filterOptions: FilterOptions): seq[LogObject]

  proc eth_getBlockReceipts(blockId: string): Opt[seq[ReceiptObject]]
  proc eth_getBlockReceipts(blockId: BlockNumber): Opt[seq[ReceiptObject]]
  proc eth_getBlockReceipts(blockId: RtBlockIdentifier): Opt[seq[ReceiptObject]]
