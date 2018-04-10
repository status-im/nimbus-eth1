# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

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

