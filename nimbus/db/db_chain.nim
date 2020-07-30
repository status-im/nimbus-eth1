# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sequtils, algorithm,
  stew/[byteutils], eth/trie/[hexary, db],
  eth/[common, rlp], chronicles,
  ../errors,  ../constants, ./storage_types,
  ../utils, ../config

type
  BaseChainDB* = ref object
    db*       : TrieDatabaseRef
    pruneTrie*: bool
    config*   : ChainConfig

    # startingBlock, currentBlock, and highestBlock
    # are progress indicator
    startingBlock*: BlockNumber
    currentBlock*: BlockNumber
    highestBlock*: BlockNumber

  TransactionKey = tuple
    blockNumber: BlockNumber
    index: int

proc newBaseChainDB*(db: TrieDatabaseRef, pruneTrie: bool = true, id: PublicNetwork = MainNet): BaseChainDB =
  new(result)
  result.db = db
  result.pruneTrie = pruneTrie
  result.config = publicChainConfig(id)

proc `$`*(db: BaseChainDB): string =
  result = "BaseChainDB"

proc exists*(self: BaseChainDB, hash: Hash256): bool =
  self.db.contains(hash.data)

proc getBlockHeader*(self: BaseChainDB; blockHash: Hash256, output: var BlockHeader): bool =
  let data = self.db.get(genericHashKey(blockHash).toOpenArray)
  if data.len != 0:
    output = rlp.decode(data, BlockHeader)
    result = true

proc getBlockHeader*(self: BaseChainDB, blockHash: Hash256): BlockHeader =
  ## Returns the requested block header as specified by block hash.
  ##
  ## Raises BlockNotFound if it is not present in the db.
  if not self.getBlockHeader(blockHash, result):
    raise newException(BlockNotFound, "No block with hash " & blockHash.data.toHex)

proc getHash(self: BaseChainDB, key: DbKey, output: var Hash256): bool {.inline.} =
  let data = self.db.get(key.toOpenArray)
  if data.len != 0:
    output = rlp.decode(data, Hash256)
    result = true

proc getCanonicalHead*(self: BaseChainDB): BlockHeader =
  var headHash: Hash256
  if not self.getHash(canonicalHeadHashKey(), headHash) or
      not self.getBlockHeader(headHash, result):
    raise newException(CanonicalHeadNotFound,
                      "No canonical head set for this chain")

proc populateProgress*(self: BaseChainDB) =
  try:
    self.startingBlock = self.getCanonicalHead().blockNumber
  except CanonicalHeadNotFound:
    self.startingBlock = toBlockNumber(0)

  self.currentBlock = self.startingBlock
  self.highestBlock = self.startingBlock

proc getBlockHash*(self: BaseChainDB, n: BlockNumber, output: var Hash256): bool {.inline.} =
  ## Return the block hash for the given block number.
  self.getHash(blockNumberToHashKey(n), output)

proc getBlockHash*(self: BaseChainDB, n: BlockNumber): Hash256 {.inline.} =
  ## Return the block hash for the given block number.
  if not self.getHash(blockNumberToHashKey(n), result):
    raise newException(BlockNotFound, "No block hash for number " & $n)

proc getBlockHeader*(self: BaseChainDB; n: BlockNumber, output: var BlockHeader): bool =
  ## Returns the block header with the given number in the canonical chain.
  var blockHash: Hash256
  if self.getBlockHash(n, blockHash):
    result = self.getBlockHeader(blockHash, output)

proc getBlockHeader*(self: BaseChainDB; n: BlockNumber): BlockHeader =
  ## Returns the block header with the given number in the canonical chain.
  ## Raises BlockNotFound error if the block is not in the DB.
  self.getBlockHeader(self.getBlockHash(n))

proc getScore*(self: BaseChainDB; blockHash: Hash256): Uint256 =
  rlp.decode(self.db.get(blockHashToScoreKey(blockHash).toOpenArray), Uint256)

proc getAncestorsHashes*(self: BaseChainDB, limit: Uint256, header: BlockHeader): seq[Hash256] =
  var ancestorCount = min(header.blockNumber, limit).truncate(int)
  var h = header

  result = newSeq[Hash256](ancestorCount)
  while ancestorCount > 0:
    h = self.getBlockHeader(h.parentHash)
    result[ancestorCount - 1] = h.hash
    dec ancestorCount

iterator findNewAncestors(self: BaseChainDB; header: BlockHeader): BlockHeader =
  ##         Returns the chain leading up from the given header until the first ancestor it has in
  ##         common with our canonical chain.
  var h = header
  var orig: BlockHeader
  while true:
    if self.getBlockHeader(h.blockNumber, orig) and orig.hash == h.hash:
      break

    yield h

    if h.parentHash == GENESIS_PARENT_HASH:
      break
    else:
      h = self.getBlockHeader(h.parentHash)

proc addBlockNumberToHashLookup*(self: BaseChainDB; header: BlockHeader) =
  self.db.put(blockNumberToHashKey(header.blockNumber).toOpenArray,
              rlp.encode(header.hash))

proc persistTransactions*(self: BaseChainDB, blockNumber:
                          BlockNumber, transactions: openArray[Transaction]): Hash256 =
  var trie = initHexaryTrie(self.db)
  for idx, tx in transactions:
    let
      encodedTx = rlp.encode(tx)
      txHash = keccakHash(encodedTx)
      txKey: TransactionKey = (blockNumber, idx)
    trie.put(rlp.encode(idx), encodedTx)
    self.db.put(transactionHashToBlockKey(txHash).toOpenArray, rlp.encode(txKey))
  trie.rootHash

proc getTransaction*(self: BaseChainDB, txRoot: Hash256, txIndex: int, res: var Transaction): bool =
  var db = initHexaryTrie(self.db, txRoot)
  let txData = db.get(rlp.encode(txIndex))
  if txData.len > 0:
    res = rlp.decode(txData, Transaction)
    result = true

iterator getBlockTransactionData*(self: BaseChainDB, transactionRoot: Hash256): seq[byte] =
  var transactionDb = initHexaryTrie(self.db, transactionRoot)
  var transactionIdx = 0
  while true:
    let transactionKey = rlp.encode(transactionIdx)
    if transactionKey in transactionDb:
      yield transactionDb.get(transactionKey)
    else:
      break
    inc transactionIdx

iterator getBlockTransactions*(self: BaseChainDB, header: BlockHeader): Transaction =
  for encodedTx in self.getBlockTransactionData(header.txRoot):
    yield rlp.decode(encodedTx, Transaction)

iterator getBlockTransactionHashes*(self: BaseChainDB, blockHeader: BlockHeader): Hash256 =
  ## Returns an iterable of the transaction hashes from th block specified
  ## by the given block header.
  for encodedTx in self.getBlockTransactionData(blockHeader.txRoot):
    yield keccakHash(encodedTx)

proc getTransactionCount*(chain: BaseChainDB, txRoot: Hash256): int =
  var trie = initHexaryTrie(chain.db, txRoot)
  var txCount = 0
  while true:
    let txKey = rlp.encode(txCount)
    if txKey notin trie:
      break
    inc txCount

proc getUnclesCount*(self: BaseChainDB, ommersHash: Hash256): int =
  if ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = self.db.get(genericHashKey(ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      let r = rlpFromBytes(encodedUncles)
      result = r.listLen

proc getUncles*(self: BaseChainDB, ommersHash: Hash256): seq[BlockHeader] =
  if ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = self.db.get(genericHashKey(ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      result = rlp.decode(encodedUncles, seq[BlockHeader])

proc getBlockBody*(self: BaseChainDB, blockHash: Hash256, output: var BlockBody): bool =
  var header: BlockHeader
  if self.getBlockHeader(blockHash, header):
    result = true
    output.transactions = @[]
    output.uncles = @[]
    for encodedTx in self.getBlockTransactionData(header.txRoot):
      output.transactions.add(rlp.decode(encodedTx, Transaction))

    if header.ommersHash != EMPTY_UNCLE_HASH:
      let encodedUncles = self.db.get(genericHashKey(header.ommersHash).toOpenArray)
      if encodedUncles.len != 0:
        output.uncles = rlp.decode(encodedUncles, seq[BlockHeader])
      else:
        result = false

proc getBlockBody*(self: BaseChainDB, hash: Hash256): BlockBody =
  if not self.getBlockBody(hash, result):
    raise newException(ValueError, "Error when retrieving block body")

proc getUncleHashes*(self: BaseChainDB, blockHashes: openArray[Hash256]): seq[Hash256] =
  for blockHash in blockHashes:
    var blockBody = self.getBlockBody(blockHash)
    for uncle in blockBody.uncles:
      result.add uncle.hash

proc getUncleHashes*(self: BaseChainDB, header: BlockHeader): seq[Hash256] =
  if header.ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = self.db.get(genericHashKey(header.ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      let uncles = rlp.decode(encodedUncles, seq[BlockHeader])
      for x in uncles:
        result.add x.hash

proc getTransactionKey*(self: BaseChainDB, transactionHash: Hash256): tuple[blockNumber: BlockNumber, index: int] {.inline.} =
  let tx = self.db.get(transactionHashToBlockKey(transactionHash).toOpenArray)

  if tx.len > 0:
    let key = rlp.decode(tx, TransactionKey)
    result = (key.blockNumber, key.index)
  else:
    result = (0.toBlockNumber, -1)

proc removeTransactionFromCanonicalChain(self: BaseChainDB, transactionHash: Hash256) {.inline.} =
  ## Removes the transaction specified by the given hash from the canonical chain.
  self.db.del(transactionHashToBlockKey(transactionHash).toOpenArray)

proc setAsCanonicalChainHead(self: BaseChainDB; headerHash: Hash256): seq[BlockHeader] =
  ##         Sets the header as the canonical chain HEAD.
  let header = self.getBlockHeader(headerHash)

  var newCanonicalHeaders = sequtils.toSeq(findNewAncestors(self, header))
  reverse(newCanonicalHeaders)
  for h in newCanonicalHeaders:
    var oldHash: Hash256
    if not self.getBlockHash(h.blockNumber, oldHash):
      break

    let oldHeader = self.getBlockHeader(oldHash)
    for txHash in self.getBlockTransactionHashes(oldHeader):
      self.removeTransactionFromCanonicalChain(txHash)
      # TODO re-add txn to internal pending pool (only if local sender)

  for h in newCanonicalHeaders:
    self.addBlockNumberToHashLookup(h)

  self.db.put(canonicalHeadHashKey().toOpenArray, rlp.encode(headerHash))

  return newCanonicalHeaders

proc setHead*(self: BaseChainDB, header: BlockHeader, writeHeader = false) =
  var headerHash = rlpHash(header)
  if writeHeader:
    self.db.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))
  self.addBlockNumberToHashLookup(header)
  self.db.put(canonicalHeadHashKey().toOpenArray, rlp.encode(headerHash))

proc headerExists*(self: BaseChainDB; blockHash: Hash256): bool =
  ## Returns True if the header with the given block hash is in our DB.
  self.db.contains(genericHashKey(blockHash).toOpenArray)

proc persistReceipts*(self: BaseChainDB, receipts: openArray[Receipt]): Hash256 =
  var trie = initHexaryTrie(self.db)
  for idx, rec in receipts:
    trie.put(rlp.encode(idx), rlp.encode(rec))
  trie.rootHash

iterator getReceipts*(self: BaseChainDB; header: BlockHeader): Receipt =
  var receiptDb = initHexaryTrie(self.db, header.receiptRoot)
  var receiptIdx = 0
  while true:
    let receiptKey = rlp.encode(receiptIdx)
    if receiptKey in receiptDb:
      let receiptData = receiptDb.get(receiptKey)
      yield rlp.decode(receiptData, Receipt)
    else:
      break
    inc receiptIdx

proc persistHeaderToDb*(self: BaseChainDB; header: BlockHeader): seq[BlockHeader] =
  let isGenesis = header.parentHash == GENESIS_PARENT_HASH
  let headerHash = header.blockHash
  if not isGenesis and not self.headerExists(header.parentHash):
    raise newException(ParentNotFound, "Cannot persist block header " &
        $headerHash & " with unknown parent " & $header.parentHash)
  self.db.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))

  let score = if isGenesis: header.difficulty
              else: self.getScore(header.parentHash) + header.difficulty
  self.db.put(blockHashToScoreKey(headerHash).toOpenArray, rlp.encode(score))

  self.addBlockNumberToHashLookup(header)

  var headScore: Uint256
  try:
    headScore = self.getScore(self.getCanonicalHead().hash)
  except CanonicalHeadNotFound:
    return self.setAsCanonicalChainHead(headerHash)

  if score > headScore:
    result = self.setAsCanonicalChainHead(headerHash)

proc persistUncles*(self: BaseChainDB, uncles: openarray[BlockHeader]): Hash256 =
  ## Persists the list of uncles to the database.
  ## Returns the uncles hash.
  let enc = rlp.encode(uncles)
  result = keccakHash(enc)
  self.db.put(genericHashKey(result).toOpenArray, enc)
