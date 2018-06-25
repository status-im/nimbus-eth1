# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import stint, tables, sequtils, algorithm, rlp, ranges, state_db, nimcrypto,
  ../errors, ../block_types, ../utils/header, ../constants, eth_common, byteutils,
  ./storage_types.nim, backends/memory_backend

type
  BaseChainDB* = ref object
    db*: MemoryDB
    # TODO db*: JournalDB

  KeyType = enum
    blockNumberToHash
    blockHashToScore

  TransactionKey = tuple
    blockNumber: BlockNumber
    index: int

proc newBaseChainDB*(db: MemoryDB): BaseChainDB =
  new(result)
  result.db = db

proc contains*(self: BaseChainDB; key: Hash256): bool =
  return self.db.contains(genericHashKey(key))

proc `$`*(db: BaseChainDB): string =
  result = "BaseChainDB"

proc getBlockHeaderByHash*(self: BaseChainDB; blockHash: Hash256): BlockHeader =
  ##         Returns the requested block header as specified by block hash.
  ##
  ##         Raises BlockNotFound if it is not present in the db.
  try:
    let blk = self.db.get(genericHashKey(blockHash))
    return decode(blk, BlockHeader)
  except KeyError:
    raise newException(BlockNotFound, "No block with hash " & blockHash.data.toHex)

proc getHash(self: BaseChainDB, key: DbKey): Hash256 {.inline.} =
  rlp.decode(self.db.get(key).toRange, Hash256)

proc getCanonicalHead*(self: BaseChainDB): BlockHeader =
  let k = canonicalHeadHashKey()
  if k notin self.db:
    raise newException(CanonicalHeadNotFound,
                      "No canonical head set for this chain")
  return self.getBlockHeaderByHash(self.getHash(k))

proc lookupBlockHash*(self: BaseChainDB; n: BlockNumber): Hash256 {.inline.} =
  ##         Return the block hash for the given block number.
  self.getHash(blockNumberToHashKey(n))

proc getCanonicalBlockHeaderByNumber*(self: BaseChainDB; n: BlockNumber): BlockHeader =
  ##         Returns the block header with the given number in the canonical chain.
  ##
  ##         Raises BlockNotFound if there's no block header with the given number in the
  ##         canonical chain.
  self.getBlockHeaderByHash(self.lookupBlockHash(n))

proc getScore*(self: BaseChainDB; blockHash: Hash256): int =
  rlp.decode(self.db.get(blockHashToScoreKey(blockHash)).toRange, int)

iterator findNewAncestors(self: BaseChainDB; header: BlockHeader): BlockHeader =
  ##         Returns the chain leading up from the given header until the first ancestor it has in
  ##         common with our canonical chain.
  var h = header
  while true:
    try:
      let orig = self.getCanonicalBlockHeaderByNumber(h.blockNumber)
      if orig.hash == h.hash:
        break
    except BlockNotFound:
      discard

    yield h

    if h.parentHash == GENESIS_PARENT_HASH:
      break
    else:
      h = self.getBlockHeaderByHash(h.parentHash)

proc addBlockNumberToHashLookup(self: BaseChainDB; header: BlockHeader) =
  self.db.set(blockNumberToHashKey(header.blockNumber), rlp.encode(header.hash))

iterator getBlockTransactionHashes(self: BaseChainDB, blockHeader: BlockHeader): Hash256 =
  ## Returns an iterable of the transaction hashes from th block specified
  ## by the given block header.
  doAssert(false, "TODO: Implement me")
  # let all_encoded_transactions = self._get_block_transaction_data(
  #   blockHeader.transactionRoot,
  # )
  # for encoded_transaction in all_encoded_transactions:
  #     yield keccak(encoded_transaction)


proc removeTransactionFromCanonicalChain(self: BaseChainDB, transactionHash: Hash256) {.inline.} =
  ## Removes the transaction specified by the given hash from the canonical chain.
  self.db.delete(transactionHashToBlockKey(transactionHash))

proc setAsCanonicalChainHead(self: BaseChainDB; headerHash: Hash256): seq[BlockHeader] =
  ##         Sets the header as the canonical chain HEAD.

  let header = self.getBlockHeaderByHash(headerHash)

  var newCanonicalHeaders = sequtils.toSeq(findNewAncestors(self, header))
  reverse(newCanonicalHeaders)
  for h in newCanonicalHeaders:
    var oldHash: Hash256
    try:
      oldHash = self.lookupBlockHash(h.blockNumber)
    except BlockNotFound:
      break

    let oldHeader = self.getBlockHeaderByHash(oldHash)
    for txHash in self.getBlockTransactionHashes(oldHeader):
      self.removeTransactionFromCanonicalChain(txHash)
      # TODO re-add txn to internal pending pool (only if local sender)

  for h in newCanonicalHeaders:
    self.addBlockNumberToHashLookup(h)

  self.db.set(canonicalHeadHashKey(), rlp.encode(header.hash))
  return newCanonicalHeaders

proc headerExists*(self: BaseChainDB; blockHash: Hash256): bool =
  ## Returns True if the header with the given block hash is in our DB.
  self.contains(blockHash)

iterator getBlockTransactionData(self: BaseChainDB, transactionRoot: Hash256): BytesRange =
  doAssert(false, "TODO: Implement me")
  # var transactionDb = HexaryTrie(self.db, transactionRoot)
  # var transactionIdx = 0
  # while true:
  #   var transactionKey = rlp.encode(transactionIdx)
  #   if transactionKey in transactionDb:
  #     var transactionData = transactionDb[transactionKey]
  #     yield transactionDb[transactionKey]
  #   else:
  #     break
  #   inc transactionIdx


# iterator getReceipts*(self: BaseChainDB; header: BlockHeader; receiptClass: typedesc): Receipt =
#   var receiptDb = HexaryTrie()
#   for receiptIdx in itertools.count():
#     var receiptKey = rlp.encode(receiptIdx)
#     if receiptKey in receiptDb:
#       var receiptData = receiptDb[receiptKey]
#       yield rlp.decode(receiptData)
#     else:
#       break

iterator getBlockTransactions(self: BaseChainDB; transactionRoot: Hash256;
                              transactionClass: typedesc): transactionClass =
  for encodedTransaction in self.getBlockTransactionData(transactionRoot):
    yield rlp.decode(encodedTransaction, transactionClass)

proc persistHeaderToDb*(self: BaseChainDB; header: BlockHeader): seq[BlockHeader] =
  let isGenesis = header.parentHash == GENESIS_PARENT_HASH
  if not isGenesis and not self.headerExists(header.parentHash):
    raise newException(ParentNotFound, "Cannot persist block header " &
        $header.hash & " with unknown parent " & $header.parentHash)
  self.db.set(genericHashKey(header.hash), rlp.encode(header))
  let score = if isGenesis: header.difficulty
              else: self.getScore(header.parentHash).u256 + header.difficulty
  self.db.set(blockHashToScoreKey(header.hash), rlp.encode(score))
  var headScore: int
  try:
    headScore = self.getScore(self.getCanonicalHead().hash)
  except CanonicalHeadNotFound:
    return self.setAsCanonicalChainHead(header.hash)

  if score > headScore.u256:
    result = self.setAsCanonicalChainHead(header.hash)


proc addTransactionToCanonicalChain(self: BaseChainDB, txHash: Hash256,
    blockHeader: BlockHeader, index: int) =
  let k: TransactionKey = (blockHeader.blockNumber, index)
  self.db.set(transactionHashToBlockKey(txHash), rlp.encode(k))

proc persistUncles*(self: BaseChainDB, uncles: openarray[BlockHeader]): Hash256 =
  ## Persists the list of uncles to the database.
  ## Returns the uncles hash.
  let enc = rlp.encode(uncles)
  result = keccak256.digest(enc.toOpenArray())
  self.db.set(genericHashKey(result), enc)

proc persistBlockToDb*(self: BaseChainDB; blk: Block) =
  ## Persist the given block's header and uncles.
  ## Assumes all block transactions have been persisted already.
  let newCanonicalHeaders = self.persistHeaderToDb(blk.header)
  for header in newCanonicalHeaders:
    var index = 0
    for txHash in self.getBlockTransactionHashes(header):
      self.addTransactionToCanonicalChain(txHash, header, index)
      inc index

  if blk.uncles.len != 0:
    let ommersHash = self.persistUncles(blk.uncles)
    assert ommersHash == blk.header.ommersHash

# proc addTransaction*(self: BaseChainDB; blockHeader: BlockHeader; indexKey: cstring;
#                     transaction: FrontierTransaction): cstring =
#   var transactionDb = HexaryTrie(self.db)
#   transactionDb[indexKey] = rlp.encode(transaction)
#   return transactionDb.rootHash

# proc addReceipt*(self: BaseChainDB; blockHeader: BlockHeader; indexKey: cstring;
#                 receipt: Receipt): cstring =
#   var receiptDb = HexaryTrie()
#   receiptDb[indexKey] = rlp.encode(receipt)
#   return receiptDb.rootHash

# proc snapshot*(self: BaseChainDB): UUID =
#   return self.db.snapshot()

# proc commit*(self: BaseChainDB; checkpoint: UUID): void =
#   self.db.commit(checkpoint)

# proc clear*(self: BaseChainDB): void =
#   self.db.clear()

method getStateDb*(self: BaseChainDB; stateRoot: Hash256; readOnly: bool = false): AccountStateDB =
  # TODO
  result = newAccountStateDB(initTable[string, string]())
