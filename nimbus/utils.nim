import eth/trie/db, eth/[trie, rlp, common], nimcrypto

export nimcrypto.`$`

proc calcRootHash[T](items: openArray[T]): Hash256 =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in items:
    tr.put(rlp.encode(i).toRange, rlp.encode(t).toRange)
  return tr.rootHash

template calcTxRoot*(transactions: openArray[Transaction]): Hash256 =
  calcRootHash(transactions)

template calcReceiptRoot*(receipts: openArray[Receipt]): Hash256 =
  calcRootHash(receipts)

func keccak*(value: openarray[byte]): Hash256 {.inline.} =
  keccak256.digest value

func generateAddress*(address: EthAddress, nonce: AccountNonce): EthAddress =
  result[0..19] = keccak(rlp.encodeList(address, nonce)).data.toOpenArray(12, 31)

func hash*(b: BlockHeader): Hash256 {.inline.} =
  rlpHash(b)
