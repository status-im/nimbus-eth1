import eth/trie/db, eth/[trie, rlp, common]

proc calcRootHash[T](items: openArray[T]): Hash256 =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in items:
    tr.put(rlp.encode(i).toRange, rlp.encode(t).toRange)
  return tr.rootHash

template calcTxRoot*(transactions: openArray[Transaction]): Hash256 =
  calcRootHash(transactions)

template calcReceiptRoot*(receipts: openArray[Receipt]): Hash256 =
  calcRootHash(receipts)
