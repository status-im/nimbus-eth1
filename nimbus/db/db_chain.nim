# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[sequtils, algorithm],
  stew/[byteutils], eth/trie/[hexary, db],
  eth/[common, rlp], chronicles,
  ".."/[errors, constants, utils/utils],
  "."/storage_types

export
  db,
  common,
  errors,
  constants

type
  ChainDBRef* = distinct TrieDatabaseRef

  TransactionKey = tuple
    blockNumber: BlockNumber
    index: int

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc new*(_: type ChainDBRef, db: TrieDatabaseRef): ChainDBRef =
  result = ChainDBRef(db)

# ------------------------------------------------------------------------------
# Public functions, Getters
# ------------------------------------------------------------------------------

# A pseudo getter mainly to allow smooth transition
# from old db object to new db object
template db*(db: ChainDBRef): TrieDatabaseRef =
  TrieDatabaseRef(db)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc exists*(db: ChainDBRef, hash: Hash256): bool =
  db.db.contains(hash.data)

proc getBlockHeader*(db: ChainDBRef; blockHash: Hash256, output: var BlockHeader): bool =
  let data = db.db.get(genericHashKey(blockHash).toOpenArray)
  if data.len != 0:
    try:
      output = rlp.decode(data, BlockHeader)
      true
    except RlpError:
      false
  else:
    false

proc getBlockHeader*(db: ChainDBRef, blockHash: Hash256): BlockHeader =
  ## Returns the requested block header as specified by block hash.
  ##
  ## Raises BlockNotFound if it is not present in the db.
  if not db.getBlockHeader(blockHash, result):
    raise newException(BlockNotFound, "No block with hash " & blockHash.data.toHex)

proc getHash(db: ChainDBRef, key: DbKey, output: var Hash256): bool {.inline.} =
  let data = db.db.get(key.toOpenArray)
  if data.len != 0:
    output = rlp.decode(data, Hash256)
    result = true

proc getCanonicalHead*(db: ChainDBRef): BlockHeader =
  var headHash: Hash256
  if not db.getHash(canonicalHeadHashKey(), headHash) or
      not db.getBlockHeader(headHash, result):
    raise newException(CanonicalHeadNotFound,
                      "No canonical head set for this chain")

proc getCanonicalHeaderHash*(db: ChainDBRef): Hash256 =
  discard db.getHash(canonicalHeadHashKey(), result)

proc getBlockHash*(db: ChainDBRef, n: BlockNumber, output: var Hash256): bool {.inline.} =
  ## Return the block hash for the given block number.
  db.getHash(blockNumberToHashKey(n), output)

proc getBlockHash*(db: ChainDBRef, n: BlockNumber): Hash256 {.inline.} =
  ## Return the block hash for the given block number.
  if not db.getHash(blockNumberToHashKey(n), result):
    raise newException(BlockNotFound, "No block hash for number " & $n)

proc getHeadBlockHash*(db: ChainDBRef): Hash256 =
  if not db.getHash(canonicalHeadHashKey(), result):
    result = Hash256()

proc getBlockHeader*(db: ChainDBRef; n: BlockNumber, output: var BlockHeader): bool =
  ## Returns the block header with the given number in the canonical chain.
  var blockHash: Hash256
  if db.getBlockHash(n, blockHash):
    result = db.getBlockHeader(blockHash, output)

proc getBlockHeaderWithHash*(db: ChainDBRef; n: BlockNumber): Option[(BlockHeader, Hash256)] =
  ## Returns the block header and its hash, with the given number in the canonical chain.
  ## Hash is returned to avoid recomputing it
  var hash: Hash256
  if db.getBlockHash(n, hash):
    # Note: this will throw if header is not present.
    var header: BlockHeader
    if db.getBlockHeader(hash, header):
      return some((header, hash))
    else:
      # this should not happen, but if it happen lets fail laudly as this means
      # something is super wrong
      raiseAssert("Corrupted database. Mapping number->hash present, without header in database")
  else:
    return none[(BlockHeader, Hash256)]()

proc getBlockHeader*(db: ChainDBRef; n: BlockNumber): BlockHeader =
  ## Returns the block header with the given number in the canonical chain.
  ## Raises BlockNotFound error if the block is not in the DB.
  db.getBlockHeader(db.getBlockHash(n))

proc getScore*(db: ChainDBRef; blockHash: Hash256): UInt256 =
  rlp.decode(db.db.get(blockHashToScoreKey(blockHash).toOpenArray), UInt256)

proc setScore*(db: ChainDBRef; blockHash: Hash256, score: UInt256) =
  ## for testing purpose
  db.db.put(blockHashToScoreKey(blockHash).toOpenArray, rlp.encode(score))

proc getTd*(db: ChainDBRef; blockHash: Hash256, td: var UInt256): bool =
  let bytes = db.db.get(blockHashToScoreKey(blockHash).toOpenArray)
  if bytes.len == 0: return false
  try:
    td = rlp.decode(bytes, UInt256)
  except RlpError:
    return false
  return true

proc headTotalDifficulty*(db: ChainDBRef): UInt256 =
  # this is actually a combination of `getHash` and `getScore`
  const key = canonicalHeadHashKey()
  let data = db.db.get(key.toOpenArray)
  if data.len == 0:
    return 0.u256

  let blockHash = rlp.decode(data, Hash256)
  rlp.decode(db.db.get(blockHashToScoreKey(blockHash).toOpenArray), UInt256)

proc getAncestorsHashes*(db: ChainDBRef, limit: UInt256, header: BlockHeader): seq[Hash256] =
  var ancestorCount = min(header.blockNumber, limit).truncate(int)
  var h = header

  result = newSeq[Hash256](ancestorCount)
  while ancestorCount > 0:
    h = db.getBlockHeader(h.parentHash)
    result[ancestorCount - 1] = h.hash
    dec ancestorCount

iterator findNewAncestors(db: ChainDBRef; header: BlockHeader): BlockHeader =
  ##         Returns the chain leading up from the given header until the first ancestor it has in
  ##         common with our canonical chain.
  var h = header
  var orig: BlockHeader
  while true:
    if db.getBlockHeader(h.blockNumber, orig) and orig.hash == h.hash:
      break

    yield h

    if h.parentHash == GENESIS_PARENT_HASH:
      break
    else:
      h = db.getBlockHeader(h.parentHash)

proc addBlockNumberToHashLookup*(db: ChainDBRef; header: BlockHeader) =
  db.db.put(blockNumberToHashKey(header.blockNumber).toOpenArray,
              rlp.encode(header.hash))

proc persistTransactions*(db: ChainDBRef, blockNumber:
                          BlockNumber, transactions: openArray[Transaction]): Hash256 =
  var trie = initHexaryTrie(db.db)
  for idx, tx in transactions:
    let
      encodedTx = rlp.encode(tx.removeNetworkPayload)
      txHash = rlpHash(tx) # beware EIP-4844
      txKey: TransactionKey = (blockNumber, idx)
    trie.put(rlp.encode(idx), encodedTx)
    db.db.put(transactionHashToBlockKey(txHash).toOpenArray, rlp.encode(txKey))
  trie.rootHash

proc getTransaction*(db: ChainDBRef, txRoot: Hash256, txIndex: int, res: var Transaction): bool =
  var db = initHexaryTrie(db.db, txRoot)
  let txData = db.get(rlp.encode(txIndex))
  if txData.len > 0:
    res = rlp.decode(txData, Transaction)
    result = true

iterator getBlockTransactionData*(db: ChainDBRef, transactionRoot: Hash256): seq[byte] =
  var transactionDb = initHexaryTrie(db.db, transactionRoot)
  var transactionIdx = 0
  while true:
    let transactionKey = rlp.encode(transactionIdx)
    if transactionKey in transactionDb:
      yield transactionDb.get(transactionKey)
    else:
      break
    inc transactionIdx

iterator getBlockTransactions*(db: ChainDBRef, header: BlockHeader): Transaction =
  for encodedTx in db.getBlockTransactionData(header.txRoot):
    yield rlp.decode(encodedTx, Transaction)

iterator getBlockTransactionHashes*(db: ChainDBRef, blockHeader: BlockHeader): Hash256 =
  ## Returns an iterable of the transaction hashes from th block specified
  ## by the given block header.
  for encodedTx in db.getBlockTransactionData(blockHeader.txRoot):
    let tx = rlp.decode(encodedTx, Transaction)
    yield rlpHash(tx) # beware EIP-4844

proc getTransactionCount*(chain: ChainDBRef, txRoot: Hash256): int =
  var trie = initHexaryTrie(chain.db, txRoot)
  var txCount = 0
  while true:
    let txKey = rlp.encode(txCount)
    if txKey in trie:
      inc txCount
    else:
      return txCount

  doAssert(false, "unreachable")

proc getUnclesCount*(db: ChainDBRef, ommersHash: Hash256): int =
  if ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = db.db.get(genericHashKey(ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      let r = rlpFromBytes(encodedUncles)
      result = r.listLen

proc getUncles*(db: ChainDBRef, ommersHash: Hash256): seq[BlockHeader] =
  if ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = db.db.get(genericHashKey(ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      result = rlp.decode(encodedUncles, seq[BlockHeader])

proc persistWithdrawals*(db: ChainDBRef, withdrawals: openArray[Withdrawal]): Hash256 =
  var trie = initHexaryTrie(db.db)
  for idx, wd in withdrawals:
    let  encodedWd = rlp.encode(wd)
    trie.put(rlp.encode(idx), encodedWd)
  trie.rootHash

iterator getWithdrawalsData*(db: ChainDBRef, withdrawalsRoot: Hash256): seq[byte] =
  var wddb = initHexaryTrie(db.db, withdrawalsRoot)
  var idx = 0
  while true:
    let wdKey = rlp.encode(idx)
    if wdKey in wddb:
      yield wddb.get(wdKey)
    else:
      break
    inc idx

proc getWithdrawals*(db: ChainDBRef, withdrawalsRoot: Hash256): seq[Withdrawal] =
  for encodedWd in db.getWithdrawalsData(withdrawalsRoot):
    result.add(rlp.decode(encodedWd, Withdrawal))

proc getBlockBody*(db: ChainDBRef, header: BlockHeader, output: var BlockBody): bool =
  result = true
  output.transactions = @[]
  output.uncles = @[]
  for encodedTx in db.getBlockTransactionData(header.txRoot):
    output.transactions.add(rlp.decode(encodedTx, Transaction))

  if header.ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = db.db.get(genericHashKey(header.ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      output.uncles = rlp.decode(encodedUncles, seq[BlockHeader])
    else:
      result = false

  if header.withdrawalsRoot.isSome:
    output.withdrawals = some(db.getWithdrawals(header.withdrawalsRoot.get))

proc getBlockBody*(db: ChainDBRef, blockHash: Hash256, output: var BlockBody): bool =
  var header: BlockHeader
  if db.getBlockHeader(blockHash, header):
    return db.getBlockBody(header, output)

proc getBlockBody*(db: ChainDBRef, hash: Hash256): BlockBody =
  if not db.getBlockBody(hash, result):
    raise newException(ValueError, "Error when retrieving block body")

proc getUncleHashes*(db: ChainDBRef, blockHashes: openArray[Hash256]): seq[Hash256] =
  for blockHash in blockHashes:
    var blockBody = db.getBlockBody(blockHash)
    for uncle in blockBody.uncles:
      result.add uncle.hash

proc getUncleHashes*(db: ChainDBRef, header: BlockHeader): seq[Hash256] =
  if header.ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = db.db.get(genericHashKey(header.ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      let uncles = rlp.decode(encodedUncles, seq[BlockHeader])
      for x in uncles:
        result.add x.hash

proc getTransactionKey*(db: ChainDBRef, transactionHash: Hash256): tuple[blockNumber: BlockNumber, index: int] {.inline.} =
  let tx = db.db.get(transactionHashToBlockKey(transactionHash).toOpenArray)

  if tx.len > 0:
    let key = rlp.decode(tx, TransactionKey)
    result = (key.blockNumber, key.index)
  else:
    result = (0.toBlockNumber, -1)

proc removeTransactionFromCanonicalChain(db: ChainDBRef, transactionHash: Hash256) {.inline.} =
  ## Removes the transaction specified by the given hash from the canonical chain.
  db.db.del(transactionHashToBlockKey(transactionHash).toOpenArray)

proc setAsCanonicalChainHead(db: ChainDBRef; headerHash: Hash256): seq[BlockHeader] =
  ##         Sets the header as the canonical chain HEAD.
  let header = db.getBlockHeader(headerHash)

  var newCanonicalHeaders = sequtils.toSeq(db.findNewAncestors(header))
  reverse(newCanonicalHeaders)
  for h in newCanonicalHeaders:
    var oldHash: Hash256
    if not db.getBlockHash(h.blockNumber, oldHash):
      break

    let oldHeader = db.getBlockHeader(oldHash)
    for txHash in db.getBlockTransactionHashes(oldHeader):
      db.removeTransactionFromCanonicalChain(txHash)
      # TODO re-add txn to internal pending pool (only if local sender)

  for h in newCanonicalHeaders:
    db.addBlockNumberToHashLookup(h)

  db.db.put(canonicalHeadHashKey().toOpenArray, rlp.encode(headerHash))

  return newCanonicalHeaders

proc headerExists*(db: ChainDBRef; blockHash: Hash256): bool =
  ## Returns True if the header with the given block hash is in our DB.
  db.db.contains(genericHashKey(blockHash).toOpenArray)

proc markCanonicalChain(db: ChainDBRef, header: BlockHeader, headerHash: Hash256): bool =
  ## mark this chain as canonical by adding block number to hash lookup
  ## down to forking point
  var
    currHash = headerHash
    currHeader = header

  # mark current header as canonical
  let key = blockNumberToHashKey(currHeader.blockNumber)
  db.db.put(key.toOpenArray, rlp.encode(currHash))

  # it is a genesis block, done
  if currHeader.parentHash == Hash256():
    return true

  # mark ancestor blocks as canonical too
  currHash = currHeader.parentHash
  if not db.getBlockHeader(currHeader.parentHash, currHeader):
    return false

  while currHash != Hash256():
    let key = blockNumberToHashKey(currHeader.blockNumber)
    let data = db.db.get(key.toOpenArray)
    if data.len == 0:
      # not marked, mark it
      db.db.put(key.toOpenArray, rlp.encode(currHash))
    elif rlp.decode(data, Hash256) != currHash:
      # replace prev chain
      db.db.put(key.toOpenArray, rlp.encode(currHash))
    else:
      # forking point, done
      break

    if currHeader.parentHash == Hash256():
      break

    currHash = currHeader.parentHash
    if not db.getBlockHeader(currHeader.parentHash, currHeader):
      return false

  return true

proc setHead*(db: ChainDBRef, blockHash: Hash256): bool =
  var header: BlockHeader
  if not db.getBlockHeader(blockHash, header):
    return false

  if not db.markCanonicalChain(header, blockHash):
    return false

  db.db.put(canonicalHeadHashKey().toOpenArray, rlp.encode(blockHash))
  return true

proc setHead*(db: ChainDBRef, header: BlockHeader, writeHeader = false): bool =
  var headerHash = rlpHash(header)
  if writeHeader:
    db.db.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))
  if not db.markCanonicalChain(header, headerHash):
    return false
  db.db.put(canonicalHeadHashKey().toOpenArray, rlp.encode(headerHash))
  return true

proc persistReceipts*(db: ChainDBRef, receipts: openArray[Receipt]): Hash256 =
  var trie = initHexaryTrie(db.db)
  for idx, rec in receipts:
    trie.put(rlp.encode(idx), rlp.encode(rec))
  trie.rootHash

iterator getReceipts*(db: ChainDBRef; receiptRoot: Hash256): Receipt =
  var receiptDb = initHexaryTrie(db.db, receiptRoot)
  var receiptIdx = 0
  while true:
    let receiptKey = rlp.encode(receiptIdx)
    if receiptKey in receiptDb:
      let receiptData = receiptDb.get(receiptKey)
      yield rlp.decode(receiptData, Receipt)
    else:
      break
    inc receiptIdx

proc getReceipts*(db: ChainDBRef; receiptRoot: Hash256): seq[Receipt] =
  var receipts = newSeq[Receipt]()
  for r in db.getReceipts(receiptRoot):
    receipts.add(r)
  return receipts

proc persistHeaderToDb*(
    db: ChainDBRef;
    header: BlockHeader;
    forceCanonical: bool;
    startOfHistory = GENESIS_PARENT_HASH;
      ): seq[BlockHeader] =
  let isStartOfHistory = header.parentHash == startOfHistory
  let headerHash = header.blockHash
  if not isStartOfHistory and not db.headerExists(header.parentHash):
    raise newException(ParentNotFound, "Cannot persist block header " &
        $headerHash & " with unknown parent " & $header.parentHash)
  db.db.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))

  let score = if isStartOfHistory: header.difficulty
              else: db.getScore(header.parentHash) + header.difficulty
  db.db.put(blockHashToScoreKey(headerHash).toOpenArray, rlp.encode(score))

  db.addBlockNumberToHashLookup(header)

  var headScore: UInt256
  try:
    headScore = db.getScore(db.getCanonicalHead().hash)
  except CanonicalHeadNotFound:
    return db.setAsCanonicalChainHead(headerHash)

  if score > headScore or forceCanonical:
    return db.setAsCanonicalChainHead(headerHash)

proc persistHeaderToDbWithoutSetHead*(
    db: ChainDBRef;
    header: BlockHeader;
    startOfHistory = GENESIS_PARENT_HASH;
      ) =
  let isStartOfHistory = header.parentHash == startOfHistory
  let headerHash = header.blockHash
  let score = if isStartOfHistory: header.difficulty
              else: db.getScore(header.parentHash) + header.difficulty

  db.db.put(blockHashToScoreKey(headerHash).toOpenArray, rlp.encode(score))
  db.db.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))

# FIXME-Adam: This seems like a bad idea. I don't see a way to get the score
# in stateless mode, but it seems dangerous to just shove the header into
# the DB *without* also storing the score.
proc persistHeaderToDbWithoutSetHeadOrScore*(db: ChainDBRef; header: BlockHeader) =
  db.addBlockNumberToHashLookup(header)
  db.db.put(genericHashKey(header.blockHash).toOpenArray, rlp.encode(header))

proc persistUncles*(db: ChainDBRef, uncles: openArray[BlockHeader]): Hash256 =
  ## Persists the list of uncles to the database.
  ## Returns the uncles hash.
  let enc = rlp.encode(uncles)
  result = keccakHash(enc)
  db.db.put(genericHashKey(result).toOpenArray, enc)

proc safeHeaderHash*(db: ChainDBRef): Hash256 =
  discard db.getHash(safeHashKey(), result)

proc safeHeaderHash*(db: ChainDBRef, headerHash: Hash256) =
  db.db.put(safeHashKey().toOpenArray, rlp.encode(headerHash))

proc finalizedHeaderHash*(db: ChainDBRef): Hash256 =
  discard db.getHash(finalizedHashKey(), result)

proc finalizedHeaderHash*(db: ChainDBRef, headerHash: Hash256) =
  db.db.put(finalizedHashKey().toOpenArray, rlp.encode(headerHash))

proc safeHeader*(db: ChainDBRef): BlockHeader =
  db.getBlockHeader(db.safeHeaderHash)

proc finalizedHeader*(db: ChainDBRef): BlockHeader =
  db.getBlockHeader(db.finalizedHeaderHash)

proc haveBlockAndState*(db: ChainDBRef, headerHash: Hash256): bool =
  var header: BlockHeader
  if not db.getBlockHeader(headerHash, header):
    return false
  # see if stateRoot exists
  db.exists(header.stateRoot)
