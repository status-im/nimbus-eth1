# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

proc eth_chaindId(): Quantity
proc eth_getBlockByHash(data: Hash256, fullTransactions: bool): Option[BlockObject]
proc eth_getBlockByNumber(
  quantityTag: string, fullTransactions: bool
): Option[BlockObject]

proc eth_getBlockTransactionCountByHash(data: Hash256): Quantity
proc eth_getTransactionReceipt(data: Hash256): Option[ReceiptObject]
proc eth_getLogs(filterOptions: FilterOptions): seq[FilterLog]

# Not supported: Only supported by Alchemy
proc eth_getBlockReceipts(data: Hash256): seq[ReceiptObject]
