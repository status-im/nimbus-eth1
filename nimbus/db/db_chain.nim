# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import strformat, tables, stint, rlp, ranges, state_db, backends / memory_backend,
  ../errors, ../utils/header, ../constants, eth_common, byteutils

type
  BaseChainDB* = ref object
    db*: MemoryDB
    # TODO db*: JournalDB

  KeyType = enum
    blockNumberToHash
    blockHashToScore

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
  var blk: seq[byte]
  try:
    blk = self.db.get(genericHashKey(blockHash))
  except KeyError:
    raise newException(BlockNotFound, "No block with hash " & blockHash.data.toHex)
  let rng = blk.toRange
  return decode(rng, BlockHeader)

# proc getCanonicalHead*(self: BaseChainDB): BlockHeader =
#   if notself.exists(CANONICALHEADHASHDBKEY):
#     raise newException(CanonicalHeadNotFound,
#                       "No canonical head set for this chain")
#   return self.getBlockHeaderByHash(self.db.get(CANONICALHEADHASHDBKEY))

proc lookupBlockHash*(self: BaseChainDB; n: BlockNumber): Hash256 {.inline.} =
  ##         Return the block hash for the given block number.
  let numberToHashKey = blockNumberToHashKey(n)
  result = rlp.decode(self.db.get(numberToHashKey).toRange, Hash256)

proc getCanonicalBlockHeaderByNumber*(self: BaseChainDB; n: BlockNumber): BlockHeader =
  ##         Returns the block header with the given number in the canonical chain.
  ##
  ##         Raises BlockNotFound if there's no block header with the given number in the
  ##         canonical chain.
  self.getBlockHeaderByHash(self.lookupBlockHash(n))

proc getScore*(self: BaseChainDB; blockHash: Hash256): int =
  rlp.decode(self.db.get(blockHashToScoreKey(blockHash)).toRange, int)

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

iterator findCommonAncestor*(self: BaseChainDB; header: BlockHeader): BlockHeader =
  ##         Returns the chain leading up from the given header until the first ancestor it has in
  ##         common with our canonical chain.
  var h = header
  while true:
    yield h
    if h.parentHash == GENESIS_PARENT_HASH:
      break
    try:
      var orig = self.getCanonicalBlockHeaderByNumber(h.blockNumber)
    except KeyError:
      discard # TODO: break??
    h = self.getBlockHeaderByHash(h.parentHash)

proc headerExists*(self: BaseChainDB; blockHash: Hash256): bool =
  ## Returns True if the header with the given block hash is in our DB.
  self.contains(blockHash)

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

method getStateDb*(self: BaseChainDB; stateRoot: Hash256; readOnly: bool = false): AccountStateDB =
  # TODO
  result = newAccountStateDB(initTable[string, string]())

# var CANONICALHEADHASHDBKEY = cstring"v1:canonical_head_hash"
