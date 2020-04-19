import eth/trie/db, eth/[trie, rlp, common], nimcrypto

export nimcrypto.`$`

proc calcRootHash[T](items: openArray[T]): Hash256 =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in items:
    tr.put(rlp.encode(i), rlp.encode(t))
  return tr.rootHash

template calcTxRoot*(transactions: openArray[Transaction]): Hash256 =
  calcRootHash(transactions)

template calcReceiptRoot*(receipts: openArray[Receipt]): Hash256 =
  calcRootHash(receipts)

func keccakHash*(value: openarray[byte]): Hash256 {.inline.} =
  keccak256.digest value

func generateAddress*(address: EthAddress, nonce: AccountNonce): EthAddress =
  result[0..19] = keccakHash(rlp.encodeList(address, nonce)).data.toOpenArray(12, 31)

func generateSafeAddress*(address: EthAddress, salt: Uint256, data: openArray[byte]): EthAddress =
  const prefix = [0xff.byte]
  let dataHash = keccakHash(data)
  var hashResult: Hash256

  var ctx: keccak256
  ctx.init()
  ctx.update(prefix)
  ctx.update(address)
  ctx.update(salt.toByteArrayBE())
  ctx.update(dataHash.data)
  ctx.finish hashResult.data
  ctx.clear()

  result[0..19] = hashResult.data.toOpenArray(12, 31)

func hash*(b: BlockHeader): Hash256 {.inline.} =
  rlpHash(b)
