# import
#   eth_utils, rlp, trie, evm.db.backends.memory, evm.db.chain

# proc makeTrieRootAndNodes*(transactions: auto; trieClass: auto): auto =
#   var
#     chaindb = BaseChainDB(MemoryDB())
#     db = chaindb.db
#     transactionDb = trieClass(db)
#   for index, transaction in transactions:
#     var indexKey = rlp.encode(index)
#     transactionDb[indexKey] = rlp.encode(transaction)
#   return (transactionDb.rootHash, transactionDb.db.wrappedDb.kvStore)

