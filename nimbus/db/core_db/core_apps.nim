# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Rewrite of `core_apps.nim` using the new `CoreDb` API. The original
## `core_apps.nim` was renamed `core_apps_legacy.nim`.

{.push gcsafe, raises: [].}

import
  std/[sequtils],
  chronicles,
  eth/[common, rlp],
  stew/byteutils,
  results,
  "../.."/[constants],
  ".."/[aristo, storage_types],
  "."/base

logScope:
  topics = "core_db"

type
  TransactionKey* = object
    blockNumber*: BlockNumber
    index*: uint

# ------------------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------------------

proc getBlockHeader*(
    db: CoreDbTxRef;
    n: BlockNumber;
      ): Result[Header, string]

proc getBlockHeader*(
    db: CoreDbTxRef,
    blockHash: Hash32;
      ): Result[Header, string]

proc getBlockHash*(
    db: CoreDbTxRef;
    n: BlockNumber;
      ): Result[Hash32, string]

proc addBlockNumberToHashLookup*(
    db: CoreDbTxRef;
    blockNumber: BlockNumber;
    blockHash: Hash32;
      )

proc getCanonicalHeaderHash*(db: CoreDbTxRef): Result[Hash32, string]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template wrapRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    return err(info & ": " & e.msg)

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator getBlockTransactionData*(
    db: CoreDbTxRef;
    txRoot: Hash32;
      ): seq[byte] =
  block body:
    if txRoot == EMPTY_ROOT_HASH:
      break body

    for idx in 0'u16..<uint16.high:
      let key = hashIndexKey(txRoot, idx)
      let txData = db.getOrEmpty(key).valueOr:
        warn "getBlockTransactionData", txRoot, key, error=($$error)
        break body
      if txData.len == 0:
        break body
      yield txData

iterator getBlockTransactions*(
    db: CoreDbTxRef;
    header: Header;
      ): Transaction =
  for encodedTx in db.getBlockTransactionData(header.txRoot):
    try:
      yield rlp.decode(encodedTx, Transaction)
    except RlpError as e:
      warn "getBlockTransactions(): Cannot decode tx",
        data = toHex(encodedTx), err=e.msg, errName=e.name

iterator getBlockTransactionHashes*(
    db: CoreDbTxRef;
    blockHeader: Header;
      ): Hash32 =
  ## Returns an iterable of the transaction hashes from th block specified
  ## by the given block header.
  for encodedTx in db.getBlockTransactionData(blockHeader.txRoot):
    yield keccak256(encodedTx)

iterator getWithdrawals*(
    db: CoreDbTxRef;
    withdrawalsRoot: Hash32;
      ): Withdrawal {.raises: [RlpError].} =
  block body:
    if withdrawalsRoot == EMPTY_ROOT_HASH:
      break body

    for idx in 0'u16..<uint16.high:
      let key = hashIndexKey(withdrawalsRoot, idx)
      let data = db.getOrEmpty(key).valueOr:
        warn "getWithdrawals", withdrawalsRoot, key, error=($$error)
        break body
      if data.len == 0:
        break body
      yield rlp.decode(data, Withdrawal)

iterator getReceipts*(
    db: CoreDbTxRef;
    receiptsRoot: Hash32;
      ): Receipt
      {.gcsafe, raises: [RlpError].} =
  block body:
    if receiptsRoot == EMPTY_ROOT_HASH:
      break body

    for idx in 0'u16..<uint16.high:
      let key = hashIndexKey(receiptsRoot, idx)
      let data = db.getOrEmpty(key).valueOr:
        warn "getReceipts", receiptsRoot, key, error=($$error)
        break body
      if data.len == 0:
        break body
      yield rlp.decode(data, Receipt)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getSavedStateBlockNumber*(
    db: CoreDbTxRef;
      ): BlockNumber =
  ## Returns the block number registered when the database was last time
  ## updated, or `BlockNumber(0)` if there was no update found.
  ##
  db.stateBlockNumber()

proc getBlockHeader*(
    db: CoreDbTxRef;
    blockHash: Hash32;
      ): Result[Header, string] =
  const info = "getBlockHeader()"
  let data = db.get(genericHashKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn info, blockHash, error=($$error)
    return err("No block with hash " & $blockHash)

  wrapRlpException info:
    return ok(rlp.decode(data, Header))

proc getBlockHeader*(
    db: CoreDbTxRef;
    n: BlockNumber;
      ): Result[Header, string] =
  ## Returns the block header with the given number in the canonical chain.
  let blockHash = ?db.getBlockHash(n)
  db.getBlockHeader(blockHash)

proc getHash(
    db: CoreDbTxRef;
    key: DbKey;
      ): Result[Hash32, string] =
  const info = "getHash()"
  let data = db.get(key.toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn info, key, error=($$error)
    return err($$error)

  wrapRlpException info:
    return ok(rlp.decode(data, Hash32))

proc getCanonicalHeaderHash*(db: CoreDbTxRef): Result[Hash32, string] =
  db.getHash(canonicalHeadHashKey())

proc getCanonicalHead*(
    db: CoreDbTxRef;
      ): Result[Header, string] =
  let headHash = ?db.getCanonicalHeaderHash()
  db.getBlockHeader(headHash)

proc getBlockHash*(
    db: CoreDbTxRef;
    n: BlockNumber;
      ): Result[Hash32, string] =
  ## Return the block hash for the given block number.
  db.getHash(blockNumberToHashKey(n))

proc getScore*(
    db: CoreDbTxRef;
    blockHash: Hash32;
      ): Opt[UInt256] =
  const info = "getScore()"
  let data = db.get(blockHashToScoreKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn info, blockHash, error=($$error)
    return Opt.none(UInt256)
  try:
    Opt.some(rlp.decode(data, UInt256))
  except RlpError as exc:
    warn info, data = data.toHex(), error=exc.msg
    Opt.none(UInt256)

proc setScore*(db: CoreDbTxRef; blockHash: Hash32, score: UInt256) =
  ## for testing purpose
  let scoreKey = blockHashToScoreKey blockHash
  db.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    warn "setScore()", scoreKey, error=($$error)
    return

proc headTotalDifficulty*(
    db: CoreDbTxRef;
      ): UInt256 =
  let blockHash = db.getCanonicalHeaderHash().valueOr:
    return 0.u256

  db.getScore(blockHash).valueOr(0.u256)

proc getAncestorsHashes*(
    db: CoreDbTxRef;
    limit: BlockNumber;
    header: Header;
      ): Result[seq[Hash32], string] =
  var
    ancestorCount = min(header.number, limit)
    h = header
    res = newSeq[Hash32](ancestorCount)
  while ancestorCount > 0:
    h = ?db.getBlockHeader(h.parentHash)
    res[ancestorCount - 1] = h.rlpHash
    dec ancestorCount
  ok(res)

proc addBlockNumberToHashLookup*(
    db: CoreDbTxRef; blockNumber: BlockNumber, blockHash: Hash32) =
  let blockNumberKey = blockNumberToHashKey(blockNumber)
  db.put(blockNumberKey.toOpenArray, rlp.encode(blockHash)).isOkOr:
    warn "addBlockNumberToHashLookup", blockNumberKey, error=($$error)

proc persistTransactions*(
    db: CoreDbTxRef;
    blockNumber: BlockNumber;
    txRoot: Hash32;
    transactions: openArray[Transaction];
      ) =
  const
    info = "persistTransactions()"

  if transactions.len == 0:
    return

  for idx, tx in transactions:
    let
      encodedTx = rlp.encode(tx)
      txHash = keccak256(encodedTx)
      blockKey = transactionHashToBlockKey(txHash)
      txKey = TransactionKey(blockNumber: blockNumber, index: idx.uint)
      key = hashIndexKey(txRoot, idx.uint16)
    db.put(key, encodedTx).isOkOr:
      warn info, idx, error=($$error)
      return
    db.put(blockKey.toOpenArray, rlp.encode(txKey)).isOkOr:
      trace info, blockKey, error=($$error)
      return

proc forgetHistory*(
    db: CoreDbTxRef;
    blockNum: BlockNumber;
      ): bool =
  ## Remove all data related to the block number argument `num`. This function
  ## returns `true`, if some history was available and deleted.
  let blockHash = db.getBlockHash(blockNum).valueOr:
    return false

  # delete blockNum->blockHash
  discard db.del(blockNumberToHashKey(blockNum).toOpenArray)
  # delete blockHash->header, stateRoot->blockNum
  discard db.del(genericHashKey(blockHash).toOpenArray)
  true

proc getTransactionByIndex*(
    db: CoreDbTxRef;
    txRoot: Hash32;
    txIndex: uint16;
      ): Result[Transaction, string] =
  const
    info = "getTransaction()"

  let key = hashIndexKey(txRoot, txIndex)
  let txData = db.getOrEmpty(key).valueOr:
    return err($$error)
  if txData.len == 0:
    return err("tx data is empty for root=" & $txRoot & " and index=" & $txIndex)

  wrapRlpException info:
    return ok(rlp.decode(txData, Transaction))

proc getTransactionCount*(
    db: CoreDbTxRef;
    txRoot: Hash32;
      ): int =
  const
    info = "getTransactionCount()"

  var txCount = 0'u16
  while true:
    let key = hashIndexKey(txRoot, txCount)
    let yes = db.hasKeyRc(key).valueOr:
      warn info, txRoot, key, error=($$error)
      return 0
    if yes:
      inc txCount
    else:
      return txCount.int

  doAssert(false, "unreachable")

proc getUnclesCount*(
    db: CoreDbTxRef;
    ommersHash: Hash32;
      ): Result[int, string] =
  const info = "getUnclesCount()"
  if ommersHash == EMPTY_UNCLE_HASH:
    return ok(0)

  wrapRlpException info:
    let encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.get(key.toOpenArray).valueOr:
        if error.error != KvtNotFound:
          warn info, ommersHash, error=($$error)
        return ok(0)
    return ok(rlpFromBytes(encodedUncles).listLen)

proc getUncles*(
    db: CoreDbTxRef;
    ommersHash: Hash32;
      ): Result[seq[Header], string] =
  const info = "getUncles()"
  if ommersHash == EMPTY_UNCLE_HASH:
    return ok(default(seq[Header]))

  wrapRlpException info:
    let  encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.get(key.toOpenArray).valueOr:
        if error.error != KvtNotFound:
          warn info, ommersHash, error=($$error)
        return ok(default(seq[Header]))
    return ok(rlp.decode(encodedUncles, seq[Header]))

proc persistWithdrawals*(
    db: CoreDbTxRef;
    withdrawalsRoot: Hash32;
    withdrawals: openArray[Withdrawal];
      ) =
  const info = "persistWithdrawals()"
  if withdrawals.len == 0:
    return
  for idx, wd in withdrawals:
    let key = hashIndexKey(withdrawalsRoot, idx.uint16)
    db.put(key, rlp.encode(wd)).isOkOr:
      warn info, idx, error=($$error)
      return

proc getWithdrawals*(
    db: CoreDbTxRef;
    withdrawalsRoot: Hash32
      ): Result[seq[Withdrawal], string] =
  wrapRlpException "getWithdrawals":
    var res: seq[Withdrawal]
    for wd in db.getWithdrawals(withdrawalsRoot):
      res.add(wd)
    return ok(res)

proc getTransactions*(
    db: CoreDbTxRef;
    txRoot: Hash32
      ): Result[seq[Transaction], string] =
  wrapRlpException "getTransactions":
    var res: seq[Transaction]
    for encodedTx in db.getBlockTransactionData(txRoot):
      res.add(rlp.decode(encodedTx, Transaction))
    return ok(res)

proc getBlockBody*(
    db: CoreDbTxRef;
    header: Header;
      ): Result[BlockBody, string] =
  wrapRlpException "getBlockBody":
    var body: BlockBody
    body.transactions = ?db.getTransactions(header.txRoot)
    body.uncles = ?db.getUncles(header.ommersHash)

    if header.withdrawalsRoot.isSome:
      let wds = ?db.getWithdrawals(header.withdrawalsRoot.get)
      body.withdrawals = Opt.some(wds)
    return ok(body)

proc getBlockBody*(
    db: CoreDbTxRef;
    blockHash: Hash32;
      ): Result[BlockBody, string] =
  let header = ?db.getBlockHeader(blockHash)
  db.getBlockBody(header)

proc getEthBlock*(
    db: CoreDbTxRef;
    hash: Hash32;
      ): Result[EthBlock, string] =
  var
    header = ?db.getBlockHeader(hash)
    blockBody = ?db.getBlockBody(hash)
  ok(EthBlock.init(move(header), move(blockBody)))

proc getEthBlock*(
    db: CoreDbTxRef;
    blockNumber: BlockNumber;
      ): Result[EthBlock, string] =
  var
    header = ?db.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = ?db.getBlockBody(headerHash)
  ok(EthBlock.init(move(header), move(blockBody)))


proc getUncleHashes*(
    db: CoreDbTxRef;
    blockHashes: openArray[Hash32];
      ): Result[seq[Hash32], string] =
  var res: seq[Hash32]
  for blockHash in blockHashes:
    let body = ?db.getBlockBody(blockHash)
    res &= body.uncles.mapIt(it.rlpHash)
  ok(res)

proc getUncleHashes*(
    db: CoreDbTxRef;
    header: Header;
      ): Result[seq[Hash32], string] =
  if header.ommersHash != EMPTY_UNCLE_HASH:
    return ok(default(seq[Hash32]))

  wrapRlpException "getUncleHashes":
    let
      key = genericHashKey(header.ommersHash)
      encodedUncles = db.get(key.toOpenArray).valueOr:
        if error.error != KvtNotFound:
          warn "getUncleHashes()", ommersHash=header.ommersHash, error=($$error)
        return ok(default(seq[Hash32]))
    return ok(rlp.decode(encodedUncles, seq[Header]).mapIt(it.rlpHash))

proc getTransactionKey*(
    db: CoreDbTxRef;
    transactionHash: Hash32;
      ): Result[TransactionKey, string] =
  wrapRlpException "getTransactionKey":
    let
      txKey = transactionHashToBlockKey(transactionHash)
      tx = db.get(txKey.toOpenArray).valueOr:
        if error.error != KvtNotFound:
          warn "getTransactionKey()", transactionHash, error=($$error)
        return ok(default(TransactionKey))
    return ok(rlp.decode(tx, TransactionKey))

proc headerExists*(db: CoreDbTxRef; blockHash: Hash32): bool =
  ## Returns True if the header with the given block hash is in our DB.
  db.hasKeyRc(genericHashKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn "headerExists()", blockHash, error=($$error)
    return false
  # => true/false

proc setHead*(
    db: CoreDbTxRef;
    blockHash: Hash32;
      ): Result[void, string] =
  let canonicalHeadHash = canonicalHeadHashKey()
  db.put(canonicalHeadHash.toOpenArray, rlp.encode(blockHash)).isOkOr:
    return err($$error)
  ok()

proc setHead*(
    db: CoreDbTxRef;
    header: Header;
    writeHeader = false;
      ): Result[void, string] =
  var headerHash = rlpHash(header)
  if writeHeader:
    db.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header)).isOkOr:
      return err($$error)
  let canonicalHeadHash = canonicalHeadHashKey()
  db.put(canonicalHeadHash.toOpenArray, rlp.encode(headerHash)).isOkOr:
    return err($$error)
  ok()

proc persistReceipts*(
    db: CoreDbTxRef;
    receiptsRoot: Hash32;
    receipts: openArray[Receipt];
      ) =
  const info = "persistReceipts()"
  if receipts.len == 0:
    return

  for idx, rec in receipts:
    let key = hashIndexKey(receiptsRoot, idx.uint16)
    db.put(key, rlp.encode(rec)).isOkOr:
      warn info, idx, error=($$error)

proc getReceipts*(
    db: CoreDbTxRef;
    receiptsRoot: Hash32;
      ): Result[seq[Receipt], string] =
  wrapRlpException "getReceipts":
    var receipts = newSeq[Receipt]()
    for r in db.getReceipts(receiptsRoot):
      receipts.add(r)
    return ok(receipts)

proc persistScore*(
    db: CoreDbTxRef;
    blockHash: Hash32;
    score: UInt256
      ): Result[void, string] =
  const
    info = "persistScore"
  let
    scoreKey = blockHashToScoreKey(blockHash)
  db.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    return err(info & ": " & $$error)
  ok()

proc persistHeader*(
    db: CoreDbTxRef;
    blockHash: Hash32;
    header: Header;
    startOfHistory = GENESIS_PARENT_HASH;
      ): Result[void, string] =
  const
    info = "persistHeader"
  let
    isStartOfHistory = header.parentHash == startOfHistory

  if not isStartOfHistory and not db.headerExists(header.parentHash):
    return err(info & ": parent header missing number " & $header.number)

  db.put(genericHashKey(blockHash).toOpenArray, rlp.encode(header)).isOkOr:
    return err(info & ": " & $$error)

  let
    parentScore = if isStartOfHistory:
      0.u256
    else:
      db.getScore(header.parentHash).valueOr:
        # TODO it's slightly wrong to fail here and leave the block in the db,
        #      but this code is going away soon enough
        return err(info & ": cannot get score")

    score = parentScore + header.difficulty
  # After EIP-3675, difficulty is set to 0 but we still save the score for
  # each block to simplify totalDifficulty reporting
  # TODO get rid of this and store a single value
  ?db.persistScore(blockHash, score)
  db.addBlockNumberToHashLookup(header.number, blockHash)
  ok()

proc persistHeaderAndSetHead*(
    db: CoreDbTxRef;
    blockHash: Hash32;
    header: Header;
    startOfHistory = GENESIS_PARENT_HASH;
      ): Result[void, string] =
  ?db.persistHeader(blockHash, header, startOfHistory)

  if header.parentHash != startOfHistory:
    let
      canonicalHash = ?db.getCanonicalHeaderHash()
      canonScore = db.getScore(canonicalHash).valueOr:
        return err("cannot load canon score")
      # TODO no need to load score from database _really_, but this code is
      #      hopefully going away soon
      score = db.getScore(blockHash).valueOr:
        return err("cannot load score")
    if score <= canonScore:
      return ok()

  db.setHead(blockHash)

proc persistHeaderAndSetHead*(
    db: CoreDbTxRef;
    header: Header;
    startOfHistory = GENESIS_PARENT_HASH;
      ): Result[void, string] =
  let
    blockHash = header.blockHash
  db.persistHeaderAndSetHead(blockHash, header, startOfHistory)

proc persistUncles*(db: CoreDbTxRef, uncles: openArray[Header]): Hash32 =
  ## Persists the list of uncles to the database.
  ## Returns the uncles hash.
  let enc = rlp.encode(uncles)
  result = keccak256(enc)
  db.put(genericHashKey(result).toOpenArray, enc).isOkOr:
    warn "persistUncles()", unclesHash=result, error=($$error)
    return EMPTY_ROOT_HASH


proc safeHeaderHash*(db: CoreDbTxRef): Hash32 =
  db.getHash(safeHashKey()).valueOr(default(Hash32))

proc safeHeaderHash*(db: CoreDbTxRef, headerHash: Hash32) =
  let safeHashKey = safeHashKey()
  db.put(safeHashKey.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn "safeHeaderHash()", safeHashKey, error=($$error)
    return

proc finalizedHeaderHash*(
    db: CoreDbTxRef;
      ): Hash32 =
  db.getHash(finalizedHashKey()).valueOr(default(Hash32))

proc finalizedHeaderHash*(db: CoreDbTxRef, headerHash: Hash32) =
  let finalizedHashKey = finalizedHashKey()
  db.put(finalizedHashKey.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn "finalizedHeaderHash()", finalizedHashKey, error=($$error)
    return

proc safeHeader*(
    db: CoreDbTxRef;
      ): Result[Header, string] =
  db.getBlockHeader(db.safeHeaderHash)

proc finalizedHeader*(
    db: CoreDbTxRef;
      ): Result[Header, string] =
  db.getBlockHeader(db.finalizedHeaderHash)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
