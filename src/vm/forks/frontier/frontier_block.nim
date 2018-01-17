import
  logging, constants, errors, transaction, "block", utils/header

type
  FrontierBlock* = object of Block
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

# method makeFrontierBlock*(header: auto; transactions: auto; uncles: void): auto =
#   if transactions is None:
#     transactions = @[]
#   if uncles is None:
#     uncles = @[]
#   result.bloomFilter = BloomFilter(header.bloom)
#   super(FrontierBlock, result).__init__()

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

