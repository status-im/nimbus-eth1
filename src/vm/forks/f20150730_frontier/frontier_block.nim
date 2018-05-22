# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../../../logging, ../../../constants, ../../../errors, ../../../transaction,
  ../../../block_types,
  ../../../utils/header

type
  FrontierBlock* = ref object of Block
    # bloomFilter*: BloomFilter
    # header*: BlockHeader
    transactions*: seq[BaseTransaction]
    # transactionClass*: Any
    stateRoot*: cstring
    # fields*: seq[(string, Function)]
    # cachedRlp: cstring
    # uncles*: void

# import
#   rlp, rlp.sedes, eth_bloom, evm.constants, evm.rlp.receipts, evm.rlp.blocks,
#   evm.rlp.headers, evm.utils.keccak, transactions

proc makeFrontierBlock*(header: BlockHeader; transactions: seq[BaseTransaction]; uncles: void): FrontierBlock =
  new result
  if transactions.len == 0:
    result.transactions = @[]
  # if uncles is None:
  #   uncles = @[]
  # result.bloomFilter = BloomFilter(header.bloom)

# method number*(self: FrontierBlock): int =
#   return self.header.blockNumber

# method hash*(self: FrontierBlock): cstring =
#   return self.header.hash

# method getTransactionClass*(cls: typedesc): typedesc =
#   return cls.transactionClass

# method getReceipts*(self: FrontierBlock; chaindb: BaseChainDB): seq[Receipt] =
#   return chaindb.getReceipts(self.header, Receipt)

# method fromHeader*(cls: typedesc; header: BlockHeader; chaindb: BaseChainDB): FrontierBlock =
#   ##         Returns the block denoted by the given block header.
#   if header.unclesHash == EMPTYUNCLEHASH:
#     var uncles = @[]
#   else:
#     uncles = chaindb.getBlockUncles(header.unclesHash)
#   var transactions = chaindb.getBlockTransactions(header, cls.getTransactionClass())
#   return cls()

# proc makeFrontierBlock*(): FrontierBlock =
#   result.transactionClass = FrontierTransaction
#   result.fields = @[("header", BlockHeader),
#                   ("transactions", CountableList(transactionClass)),
#                   ("uncles", CountableList(BlockHeader))]
#   result.bloomFilter = nil

