# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## This file was renamed from `core_apps.nim`.

{.push raises: [].}

import
  std/[algorithm, options, sequtils],
  chronicles,
  eth/[common, rlp],
  stew/byteutils,
  "../.."/[errors, constants],
  ../storage_types,
  "."/base

logScope:
  topics = "core_db-apps"

type
  TransactionKey = tuple
    blockNumber: BlockNumber
    index: int

# ------------------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------------------

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var BlockHeader;
      ): bool
      {.gcsafe, raises: [RlpError].}

proc getBlockHeader*(
    db: CoreDbRef,
    blockHash: Hash256;
      ): BlockHeader
      {.gcsafe, raises: [BlockNotFound].}

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var Hash256;
      ): bool
      {.gcsafe, raises: [RlpError].}

proc addBlockNumberToHashLookup*(
    db: CoreDbRef;
    header: BlockHeader;
      ) {.gcsafe.}

proc getBlockHeader*(
    db: CoreDbRef;
    blockHash: Hash256;
    output: var BlockHeader;
      ): bool
      {.gcsafe.}

# Copied from `utils/utils` which cannot be imported here in order to
# avoid circular imports.
func hash(b: BlockHeader): Hash256

# ------------------------------------------------------------------------------
# Private iterators
# ------------------------------------------------------------------------------

iterator findNewAncestors(
    db: CoreDbRef;
    header: BlockHeader;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  ## Returns the chain leading up from the given header until the first
  ## ancestor it has in common with our canonical chain.
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

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator getBlockTransactionData*(
    db: CoreDbRef;
    transactionRoot: Hash256;
      ): seq[byte]
      {.gcsafe, raises: [RlpError].} =
  var transactionDb = db.mptPrune transactionRoot
  var transactionIdx = 0
  while true:
    let transactionKey = rlp.encode(transactionIdx)
    if transactionKey in transactionDb:
      yield transactionDb.get(transactionKey)
    else:
      break
    inc transactionIdx

iterator getBlockTransactions*(
    db: CoreDbRef;
    header: BlockHeader;
      ): Transaction
      {.gcsafe, raises: [RlpError].} =
  for encodedTx in db.getBlockTransactionData(header.txRoot):
    yield rlp.decode(encodedTx, Transaction)

iterator getBlockTransactionHashes*(
    db: CoreDbRef;
    blockHeader: BlockHeader;
      ): Hash256
      {.gcsafe, raises: [RlpError].} =
  ## Returns an iterable of the transaction hashes from th block specified
  ## by the given block header.
  for encodedTx in db.getBlockTransactionData(blockHeader.txRoot):
    let tx = rlp.decode(encodedTx, Transaction)
    yield rlpHash(tx) # beware EIP-4844

iterator getWithdrawalsData*(
    db: CoreDbRef;
    withdrawalsRoot: Hash256;
      ): seq[byte]
      {.gcsafe, raises: [RlpError].} =
  var wddb = db.mptPrune withdrawalsRoot
  var idx = 0
  while true:
    let wdKey = rlp.encode(idx)
    if wdKey in wddb:
      yield wddb.get(wdKey)
    else:
      break
    inc idx

iterator getReceipts*(
    db: CoreDbRef;
    receiptRoot: Hash256;
      ): Receipt
      {.gcsafe, raises: [RlpError].} =
  var receiptDb = db.mptPrune receiptRoot
  var receiptIdx = 0
  while true:
    let receiptKey = rlp.encode(receiptIdx)
    if receiptKey in receiptDb:
      let receiptData = receiptDb.get(receiptKey)
      yield rlp.decode(receiptData, Receipt)
    else:
      break
    inc receiptIdx

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func hash(b: BlockHeader): Hash256 =
  rlpHash(b)

proc removeTransactionFromCanonicalChain(
    db: CoreDbRef;
    transactionHash: Hash256;
      ) =
  ## Removes the transaction specified by the given hash from the canonical
  ## chain.
  db.kvt.del(transactionHashToBlockKey(transactionHash).toOpenArray)

proc setAsCanonicalChainHead(
    db: CoreDbRef;
    headerHash: Hash256;
      ): seq[BlockHeader]
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  ## Sets the header as the canonical chain HEAD.
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

  db.kvt.put(canonicalHeadHashKey().toOpenArray, rlp.encode(headerHash))

  return newCanonicalHeaders

proc markCanonicalChain(
    db: CoreDbRef;
    header: BlockHeader;
    headerHash: Hash256;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  ## mark this chain as canonical by adding block number to hash lookup
  ## down to forking point
  var
    currHash = headerHash
    currHeader = header

  # mark current header as canonical
  let key = blockNumberToHashKey(currHeader.blockNumber)
  db.kvt.put(key.toOpenArray, rlp.encode(currHash))

  # it is a genesis block, done
  if currHeader.parentHash == Hash256():
    return true

  # mark ancestor blocks as canonical too
  currHash = currHeader.parentHash
  if not db.getBlockHeader(currHeader.parentHash, currHeader):
    return false

  while currHash != Hash256():
    let key = blockNumberToHashKey(currHeader.blockNumber)
    let data = db.kvt.get(key.toOpenArray)
    if data.len == 0:
      # not marked, mark it
      db.kvt.put(key.toOpenArray, rlp.encode(currHash))
    elif rlp.decode(data, Hash256) != currHash:
      # replace prev chain
      db.kvt.put(key.toOpenArray, rlp.encode(currHash))
    else:
      # forking point, done
      break

    if currHeader.parentHash == Hash256():
      break

    currHash = currHeader.parentHash
    if not db.getBlockHeader(currHeader.parentHash, currHeader):
      return false

  return true


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc exists*(db: CoreDbRef, hash: Hash256): bool =
  db.kvt.contains(hash.data)

proc getBlockHeader*(
    db: CoreDbRef;
    blockHash: Hash256;
    output: var BlockHeader;
      ): bool =
  let data = db.kvt.get(genericHashKey(blockHash).toOpenArray)
  if data.len != 0:
    try:
      output = rlp.decode(data, BlockHeader)
      true
    except RlpError:
      false
  else:
    false

proc getBlockHeader*(
    db: CoreDbRef,
    blockHash: Hash256;
      ): BlockHeader =
  ## Returns the requested block header as specified by block hash.
  ##
  ## Raises BlockNotFound if it is not present in the db.
  if not db.getBlockHeader(blockHash, result):
    raise newException(
      BlockNotFound, "No block with hash " & blockHash.data.toHex)

proc getHash(
    db: CoreDbRef;
    key: DbKey;
    output: var Hash256;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  let data = db.kvt.get(key.toOpenArray)
  if data.len != 0:
    output = rlp.decode(data, Hash256)
    result = true

proc getCanonicalHead*(
    db: CoreDbRef;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,EVMError].} =
  var headHash: Hash256
  if not db.getHash(canonicalHeadHashKey(), headHash) or
      not db.getBlockHeader(headHash, result):
    raise newException(
      CanonicalHeadNotFound, "No canonical head set for this chain")

proc getCanonicalHeaderHash*(
    db: CoreDbRef;
      ): Hash256
      {.gcsafe, raises: [RlpError].}=
  discard db.getHash(canonicalHeadHashKey(), result)

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var Hash256;
      ): bool =
  ## Return the block hash for the given block number.
  db.getHash(blockNumberToHashKey(n), output)

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Hash256
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  ## Return the block hash for the given block number.
  if not db.getHash(blockNumberToHashKey(n), result):
    raise newException(BlockNotFound, "No block hash for number " & $n)

proc getHeadBlockHash*(
    db: CoreDbRef;
      ): Hash256
      {.gcsafe, raises: [RlpError].} =
  if not db.getHash(canonicalHeadHashKey(), result):
    result = Hash256()

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var BlockHeader;
      ): bool =
  ## Returns the block header with the given number in the canonical chain.
  var blockHash: Hash256
  if db.getBlockHash(n, blockHash):
    result = db.getBlockHeader(blockHash, output)

proc getBlockHeaderWithHash*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Option[(BlockHeader, Hash256)]
      {.gcsafe, raises: [RlpError].} =
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

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  ## Returns the block header with the given number in the canonical chain.
  ## Raises BlockNotFound error if the block is not in the DB.
  db.getBlockHeader(db.getBlockHash(n))

proc getScore*(
    db: CoreDbRef;
    blockHash: Hash256;
      ): UInt256
      {.gcsafe, raises: [RlpError].} =
  rlp.decode(db.kvt.get(blockHashToScoreKey(blockHash).toOpenArray), UInt256)

proc setScore*(db: CoreDbRef; blockHash: Hash256, score: UInt256) =
  ## for testing purpose
  db.kvt.put(blockHashToScoreKey(blockHash).toOpenArray, rlp.encode(score))

proc getTd*(db: CoreDbRef; blockHash: Hash256, td: var UInt256): bool =
  let bytes = db.kvt.get(blockHashToScoreKey(blockHash).toOpenArray)
  if bytes.len == 0: return false
  try:
    td = rlp.decode(bytes, UInt256)
  except RlpError:
    return false
  return true

proc headTotalDifficulty*(
    db: CoreDbRef;
      ): UInt256
      {.gcsafe, raises: [RlpError].} =
  # this is actually a combination of `getHash` and `getScore`
  const key = canonicalHeadHashKey()
  let data = db.kvt.get(key.toOpenArray)
  if data.len == 0:
    return 0.u256

  let blockHash = rlp.decode(data, Hash256)
  rlp.decode(db.kvt.get(blockHashToScoreKey(blockHash).toOpenArray), UInt256)

proc getAncestorsHashes*(
    db: CoreDbRef;
    limit: UInt256;
    header: BlockHeader;
      ): seq[Hash256]
      {.gcsafe, raises: [BlockNotFound].} =
  var ancestorCount = min(header.blockNumber, limit).truncate(int)
  var h = header

  result = newSeq[Hash256](ancestorCount)
  while ancestorCount > 0:
    h = db.getBlockHeader(h.parentHash)
    result[ancestorCount - 1] = h.hash
    dec ancestorCount

proc addBlockNumberToHashLookup*(db: CoreDbRef; header: BlockHeader) =
  db.kvt.put(
    blockNumberToHashKey(header.blockNumber).toOpenArray,
    rlp.encode(header.hash))

proc persistTransactions*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
    transactions: openArray[Transaction];
      ): Hash256
      {.gcsafe, raises: [CatchableError].} =
  var trie = db.mptPrune()
  for idx, tx in transactions:
    let
      encodedTx = rlp.encode(tx.removeNetworkPayload)
      txHash = rlpHash(tx) # beware EIP-4844
      txKey: TransactionKey = (blockNumber, idx)
    trie.put(rlp.encode(idx), encodedTx)
    db.kvt.put(transactionHashToBlockKey(txHash).toOpenArray, rlp.encode(txKey))
  trie.rootHash

proc getTransaction*(
    db: CoreDbRef;
    txRoot: Hash256;
    txIndex: int;
    res: var Transaction;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  var db = db.mptPrune txRoot
  let txData = db.get(rlp.encode(txIndex))
  if txData.len > 0:
    res = rlp.decode(txData, Transaction)
    result = true

proc getTransactionCount*(
    db: CoreDbRef;
    txRoot: Hash256;
      ): int
      {.gcsafe, raises: [RlpError].} =
  var trie = db.mptPrune txRoot
  var txCount = 0
  while true:
    let txKey = rlp.encode(txCount)
    if txKey in trie:
      inc txCount
    else:
      return txCount

  doAssert(false, "unreachable")

proc getUnclesCount*(
    db: CoreDbRef;
    ommersHash: Hash256;
      ): int
      {.gcsafe, raises: [RlpError].} =
  if ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = db.kvt.get(genericHashKey(ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      let r = rlpFromBytes(encodedUncles)
      result = r.listLen

proc getUncles*(
    db: CoreDbRef;
    ommersHash: Hash256;
      ): seq[BlockHeader]
      {.gcsafe, raises: [RlpError].} =
  if ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = db.kvt.get(genericHashKey(ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      result = rlp.decode(encodedUncles, seq[BlockHeader])

proc persistWithdrawals*(
    db: CoreDbRef;
    withdrawals: openArray[Withdrawal];
      ): Hash256
      {.gcsafe, raises: [CatchableError].} =
  var trie = db.mptPrune()
  for idx, wd in withdrawals:
    let  encodedWd = rlp.encode(wd)
    trie.put(rlp.encode(idx), encodedWd)
  trie.rootHash

proc getWithdrawals*(
    db: CoreDbRef;
    withdrawalsRoot: Hash256;
      ): seq[Withdrawal]
      {.gcsafe, raises: [RlpError].} =
  for encodedWd in db.getWithdrawalsData(withdrawalsRoot):
    result.add(rlp.decode(encodedWd, Withdrawal))

proc getBlockBody*(
    db: CoreDbRef;
    header: BlockHeader;
    output: var BlockBody;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  result = true
  output.transactions = @[]
  output.uncles = @[]
  for encodedTx in db.getBlockTransactionData(header.txRoot):
    output.transactions.add(rlp.decode(encodedTx, Transaction))

  if header.ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = db.kvt.get(genericHashKey(header.ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      output.uncles = rlp.decode(encodedUncles, seq[BlockHeader])
    else:
      result = false

  if header.withdrawalsRoot.isSome:
    output.withdrawals = some(db.getWithdrawals(header.withdrawalsRoot.get))

proc getBlockBody*(
    db: CoreDbRef;
    blockHash: Hash256;
    output: var BlockBody;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  var header: BlockHeader
  if db.getBlockHeader(blockHash, header):
    return db.getBlockBody(header, output)

proc getBlockBody*(
    db: CoreDbRef;
    hash: Hash256;
      ): BlockBody
      {.gcsafe, raises: [RlpError,ValueError].} =
  if not db.getBlockBody(hash, result):
    raise newException(ValueError, "Error when retrieving block body")

proc getUncleHashes*(
    db: CoreDbRef;
    blockHashes: openArray[Hash256];
      ): seq[Hash256]
      {.gcsafe, raises: [RlpError,ValueError].} =
  for blockHash in blockHashes:
    var blockBody = db.getBlockBody(blockHash)
    for uncle in blockBody.uncles:
      result.add uncle.hash

proc getUncleHashes*(
    db: CoreDbRef;
    header: BlockHeader;
      ): seq[Hash256]
      {.gcsafe, raises: [RlpError].} =
  if header.ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = db.kvt.get(genericHashKey(header.ommersHash).toOpenArray)
    if encodedUncles.len != 0:
      let uncles = rlp.decode(encodedUncles, seq[BlockHeader])
      for x in uncles:
        result.add x.hash

proc getTransactionKey*(
    db: CoreDbRef;
    transactionHash: Hash256;
      ): tuple[blockNumber: BlockNumber, index: int]
      {.gcsafe, raises: [RlpError].} =
  let tx = db.kvt.get(transactionHashToBlockKey(transactionHash).toOpenArray)

  if tx.len > 0:
    let key = rlp.decode(tx, TransactionKey)
    result = (key.blockNumber, key.index)
  else:
    result = (0.toBlockNumber, -1)

proc headerExists*(db: CoreDbRef; blockHash: Hash256): bool =
  ## Returns True if the header with the given block hash is in our DB.
  db.kvt.contains(genericHashKey(blockHash).toOpenArray)

proc setHead*(
    db: CoreDbRef;
    blockHash: Hash256;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  var header: BlockHeader
  if not db.getBlockHeader(blockHash, header):
    return false

  if not db.markCanonicalChain(header, blockHash):
    return false

  db.kvt.put(canonicalHeadHashKey().toOpenArray, rlp.encode(blockHash))
  return true

proc setHead*(
    db: CoreDbRef;
    header: BlockHeader;
    writeHeader = false;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  var headerHash = rlpHash(header)
  if writeHeader:
    db.kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))
  if not db.markCanonicalChain(header, headerHash):
    return false
  db.kvt.put(canonicalHeadHashKey().toOpenArray, rlp.encode(headerHash))
  return true

proc persistReceipts*(
    db: CoreDbRef;
    receipts: openArray[Receipt];
      ): Hash256
      {.gcsafe, raises: [CatchableError].} =
  var trie = db.mptPrune()
  for idx, rec in receipts:
    trie.put(rlp.encode(idx), rlp.encode(rec))
  trie.rootHash

proc getReceipts*(
    db: CoreDbRef;
    receiptRoot: Hash256;
      ): seq[Receipt]
      {.gcsafe, raises: [RlpError].} =
  var receipts = newSeq[Receipt]()
  for r in db.getReceipts(receiptRoot):
    receipts.add(r)
  return receipts

proc persistHeaderToDb*(
    db: CoreDbRef;
    header: BlockHeader;
    forceCanonical: bool;
    startOfHistory = GENESIS_PARENT_HASH;
      ): seq[BlockHeader]
      {.gcsafe, raises: [RlpError,EVMError].} =
  let isStartOfHistory = header.parentHash == startOfHistory
  let headerHash = header.blockHash
  if not isStartOfHistory and not db.headerExists(header.parentHash):
    raise newException(ParentNotFound, "Cannot persist block header " &
        $headerHash & " with unknown parent " & $header.parentHash)
  db.kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))

  let score = if isStartOfHistory: header.difficulty
              else: db.getScore(header.parentHash) + header.difficulty
  db.kvt.put(blockHashToScoreKey(headerHash).toOpenArray, rlp.encode(score))

  db.addBlockNumberToHashLookup(header)

  var headScore: UInt256
  try:
    headScore = db.getScore(db.getCanonicalHead().hash)
  except CanonicalHeadNotFound:
    return db.setAsCanonicalChainHead(headerHash)

  if score > headScore or forceCanonical:
    return db.setAsCanonicalChainHead(headerHash)

proc persistHeaderToDbWithoutSetHead*(
    db: CoreDbRef;
    header: BlockHeader;
    startOfHistory = GENESIS_PARENT_HASH;
      ) {.gcsafe, raises: [RlpError].} =
  let isStartOfHistory = header.parentHash == startOfHistory
  let headerHash = header.blockHash
  let score = if isStartOfHistory: header.difficulty
              else: db.getScore(header.parentHash) + header.difficulty

  db.kvt.put(blockHashToScoreKey(headerHash).toOpenArray, rlp.encode(score))
  db.kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))

# FIXME-Adam: This seems like a bad idea. I don't see a way to get the score
# in stateless mode, but it seems dangerous to just shove the header into
# the DB *without* also storing the score.
proc persistHeaderToDbWithoutSetHeadOrScore*(db: CoreDbRef; header: BlockHeader) =
  db.addBlockNumberToHashLookup(header)
  db.kvt.put(genericHashKey(header.blockHash).toOpenArray, rlp.encode(header))

proc persistUncles*(db: CoreDbRef, uncles: openArray[BlockHeader]): Hash256 =
  ## Persists the list of uncles to the database.
  ## Returns the uncles hash.
  let enc = rlp.encode(uncles)
  result = keccakHash(enc)
  db.kvt.put(genericHashKey(result).toOpenArray, enc)

proc safeHeaderHash*(
    db: CoreDbRef;
      ): Hash256
      {.gcsafe, raises: [RlpError].} =
  discard db.getHash(safeHashKey(), result)

proc safeHeaderHash*(db: CoreDbRef, headerHash: Hash256) =
  db.kvt.put(safeHashKey().toOpenArray, rlp.encode(headerHash))

proc finalizedHeaderHash*(
    db: CoreDbRef;
      ): Hash256
      {.gcsafe, raises: [RlpError].} =
  discard db.getHash(finalizedHashKey(), result)

proc finalizedHeaderHash*(db: CoreDbRef, headerHash: Hash256) =
  db.kvt.put(finalizedHashKey().toOpenArray, rlp.encode(headerHash))

proc safeHeader*(
    db: CoreDbRef;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  db.getBlockHeader(db.safeHeaderHash)

proc finalizedHeader*(
    db: CoreDbRef;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  db.getBlockHeader(db.finalizedHeaderHash)

proc haveBlockAndState*(db: CoreDbRef, headerHash: Hash256): bool =
  var header: BlockHeader
  if not db.getBlockHeader(headerHash, header):
    return false
  # see if stateRoot exists
  db.exists(header.stateRoot)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
