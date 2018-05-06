# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import strformat, tables, stint, state_db, backends / memory_backend

type
  BaseChainDB* = ref object
    db*: MemoryDB
    # TODO db*: JournalDB

proc newBaseChainDB*(db: MemoryDB): BaseChainDB =
  new(result)
  result.db = db

proc exists*(self: BaseChainDB; key: string): bool =
  return self.db.exists(key)

proc `$`*(db: BaseChainDB): string =
  result = "BaseChainDB"

# proc getCanonicalHead*(self: BaseChainDB): BlockHeader =
#   if notself.exists(CANONICALHEADHASHDBKEY):
#     raise newException(CanonicalHeadNotFound,
#                       "No canonical head set for this chain")
#   return self.getBlockHeaderByHash(self.db.get(CANONICALHEADHASHDBKEY))

# proc getCanonicalBlockHeaderByNumber*(self: BaseChainDB; blockNumber: int): BlockHeader =
#   ##         Returns the block header with the given number in the canonical chain.
#   ##
#   ##         Raises BlockNotFound if there's no block header with the given number in the
#   ##         canonical chain.
#   validateUint256(blockNumber)
#   return self.getBlockHeaderByHash(self.lookupBlockHash(blockNumber))

# proc getScore*(self: BaseChainDB; blockHash: cstring): int =
#   return rlp.decode(self.db.get(makeBlockHashToScoreLookupKey(blockHash)))

# proc setAsCanonicalChainHead*(self: BaseChainDB; header: BlockHeader): void =
#   ##         Sets the header as the canonical chain HEAD.
#   for h in reversed(self.findCommonAncestor(header)):
#     self.addBlockNumberToHashLookup(h)
#   try:
#     self.getBlockHeaderByHash(header.hash)
#   except BlockNotFound:
#     raise newException(ValueError, "Cannot use unknown block hash as canonical head: {}".format(
#         header.hash))
#   self.db.set(CANONICALHEADHASHDBKEY, header.hash)

# iterator findCommonAncestor*(self: BaseChainDB; header: BlockHeader): BlockHeader =
#   ##         Returns the chain leading up from the given header until the first ancestor it has in
#   ##         common with our canonical chain.
#   var h = header
#   while true:
#     yield h
#     if h.parentHash == GENESISPARENTHASH:
#       break
#     try:
#       var orig = self.getCanonicalBlockHeaderByNumber(h.blockNumber)
#     except KeyError:
#       nil
#     h = self.getBlockHeaderByHash(h.parentHash)

# proc getBlockHeaderByHash*(self: BaseChainDB; blockHash: cstring): BlockHeader =
#   ##         Returns the requested block header as specified by block hash.
#   ##
#   ##         Raises BlockNotFound if it is not present in the db.
#   validateWord(blockHash)
#   try:
#     var block = self.db.get(blockHash)
#   except KeyError:
#     raise newException(BlockNotFound, "No block with hash {0} found".format(
#         encodeHex(blockHash)))
#   return rlp.decode(block)

# proc headerExists*(self: BaseChainDB; blockHash: cstring): bool =
#   ## Returns True if the header with the given block hash is in our DB.
#   return self.db.exists(blockHash)

# proc lookupBlockHash*(self: BaseChainDB; blockNumber: int): cstring =
#   ##         Return the block hash for the given block number.
#   validateUint256(blockNumber)
#   var
#     numberToHashKey = makeBlockNumberToHashLookupKey(blockNumber)
#     blockHash = rlp.decode(self.db.get(numberToHashKey))
#   return blockHash

# iterator getReceipts*(self: BaseChainDB; header: BlockHeader; receiptClass: typedesc): Receipt =
#   var receiptDb = HexaryTrie()
#   for receiptIdx in itertools.count():
#     var receiptKey = rlp.encode(receiptIdx)
#     if receiptKey in receiptDb:
#       var receiptData = receiptDb[receiptKey]
#       yield rlp.decode(receiptData)
#     else:
#       break

# iterator getBlockTransactions*(self: BaseChainDB; blockHeader: BlockHeader;
#                               transactionClass: typedesc): FrontierTransaction =
#   var transactionDb = HexaryTrie(self.db)
#   for transactionIdx in itertools.count():
#     var transactionKey = rlp.encode(transactionIdx)
#     if transactionKey in transactionDb:
#       var transactionData = transactionDb[transactionKey]
#       yield rlp.decode(transactionData)
#     else:
#       break

# proc addBlockNumberToHashLookup*(self: BaseChainDB; header: BlockHeader): void =
#   var blockNumberToHashKey = makeBlockNumberToHashLookupKey(header.blockNumber)
#   self.db.set(blockNumberToHashKey, rlp.encode(header.hash))

# proc persistHeaderToDb*(self: BaseChainDB; header: BlockHeader): void =
#   if header.parentHash != GENESISPARENTHASH and
#       notself.headerExists(header.parentHash):
#     raise newException(ParentNotFound, "Cannot persist block header ({}) with unknown parent ({})".format(
#         encodeHex(header.hash), encodeHex(header.parentHash)))
#   self.db.set(header.hash, rlp.encode(header))
#   if header.parentHash == GENESISPARENTHASH:
#     var score = header.difficulty
#   else:
#     score = self.getScore(header.parentHash) + header.difficulty
#   self.db.set(makeBlockHashToScoreLookupKey(header.hash), rlp.encode(score))
#   try:
#     var headScore = self.getScore(self.getCanonicalHead().hash)
#   except CanonicalHeadNotFound:
#     self.setAsCanonicalChainHead(header)

# proc persistBlockToDb*(self: BaseChainDB; block: FrontierBlock): void =
#   self.persistHeaderToDb(block.header)
#   var transactionDb = HexaryTrie(self.db)
#   for i in 0 ..< len(block.transactions):
#     var indexKey = rlp.encode(i)
#     transactionDb[indexKey] = rlp.encode(block.transactions[i])
#   nil
#   self.db.set(block.header.unclesHash, rlp.encode(block.uncles))

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

method getStateDb*(self: BaseChainDB; stateRoot: string; readOnly: bool = false): AccountStateDB =
  # TODO
  result = newAccountStateDB(initTable[string, string]())

# var CANONICALHEADHASHDBKEY = cstring"v1:canonical_head_hash"
