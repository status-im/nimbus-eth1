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
  std/[algorithm, sequtils],
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
    db: CoreDbRef;
    n: BlockNumber;
      ): Result[Header, string]

proc getBlockHeader*(
    db: CoreDbRef,
    blockHash: Hash32;
      ): Result[Header, string]

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Result[Hash32, string]

proc addBlockNumberToHashLookup*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
    blockHash: Hash32;
      )

proc getCanonicalHeaderHash*(db: CoreDbRef): Result[Hash32, string]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template wrapRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    return err(info & ": " & e.msg)

# ------------------------------------------------------------------------------
# Private iterators
# ------------------------------------------------------------------------------

proc findNewAncestors(
    db: CoreDbRef;
    header: Header;
      ): Result[seq[Header], string] =
  ## Returns the chain leading up from the given header until the first
  ## ancestor it has in common with our canonical chain.
  var
    h = header
    res = newSeq[Header]()
  while true:
    let orig = ?db.getBlockHeader(h.number)
    if orig.rlpHash == h.rlpHash:
      break

    res.add(h)

    if h.parentHash == GENESIS_PARENT_HASH:
      break
    else:
      h = ?db.getBlockHeader(h.parentHash)

  ok(res)

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator getBlockTransactionData*(
    db: CoreDbRef;
    txRoot: Hash32;
      ): seq[byte] =
  block body:
    if txRoot == EMPTY_ROOT_HASH:
      break body

    let kvt = db.ctx.getKvt()
    for idx in 0'u16..<uint16.high:
      let key = hashIndexKey(txRoot, idx)
      let txData = kvt.getOrEmpty(key).valueOr:
        warn "getBlockTransactionData", txRoot, key, error=($$error)
        break body
      if txData.len == 0:
        break body
      yield txData

iterator getBlockTransactions*(
    db: CoreDbRef;
    header: Header;
      ): Transaction =
  for encodedTx in db.getBlockTransactionData(header.txRoot):
    try:
      yield rlp.decode(encodedTx, Transaction)
    except RlpError as e:
      warn "getBlockTransactions(): Cannot decode tx",
        data = toHex(encodedTx), err=e.msg, errName=e.name

iterator getBlockTransactionHashes*(
    db: CoreDbRef;
    blockHeader: Header;
      ): Hash32 =
  ## Returns an iterable of the transaction hashes from th block specified
  ## by the given block header.
  for encodedTx in db.getBlockTransactionData(blockHeader.txRoot):
    yield keccak256(encodedTx)

iterator getWithdrawals*(
    db: CoreDbRef;
    withdrawalsRoot: Hash32;
      ): Withdrawal {.raises: [RlpError].} =
  block body:
    if withdrawalsRoot == EMPTY_ROOT_HASH:
      break body

    let kvt = db.ctx.getKvt()
    for idx in 0'u16..<uint16.high:
      let key = hashIndexKey(withdrawalsRoot, idx)
      let data = kvt.getOrEmpty(key).valueOr:
        warn "getWithdrawals", withdrawalsRoot, key, error=($$error)
        break body
      if data.len == 0:
        break body
      yield rlp.decode(data, Withdrawal)

iterator getReceipts*(
    db: CoreDbRef;
    receiptsRoot: Hash32;
      ): Receipt
      {.gcsafe, raises: [RlpError].} =
  block body:
    if receiptsRoot == EMPTY_ROOT_HASH:
      break body

    let kvt = db.ctx.getKvt()
    for idx in 0'u16..<uint16.high:
      let key = hashIndexKey(receiptsRoot, idx)
      let data = kvt.getOrEmpty(key).valueOr:
        warn "getReceipts", receiptsRoot, key, error=($$error)
        break body
      if data.len == 0:
        break body
      yield rlp.decode(data, Receipt)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc removeTransactionFromCanonicalChain(
    db: CoreDbRef;
    transactionHash: Hash32;
      ) =
  ## Removes the transaction specified by the given hash from the canonical
  ## chain.
  db.ctx.getKvt.del(transactionHashToBlockKey(transactionHash).toOpenArray).isOkOr:
    warn "removeTransactionFromCanonicalChain",
      transactionHash, error=($$error)

proc setAsCanonicalChainHead(
    db: CoreDbRef;
    headerHash: Hash32;
    header: Header;
      ): Result[void, string] =
  ## Sets the header as the canonical chain HEAD.
  # TODO This code handles reorgs - this should be moved elsewhere because we'll
  #      be handling reorgs mainly in-memory
  if header.number == 0 or
      db.getCanonicalHeaderHash().valueOr(default(Hash32)) != header.parentHash:
    var newCanonicalHeaders = ?db.findNewAncestors(header)
    reverse(newCanonicalHeaders)
    for h in newCanonicalHeaders:
      let
        oldHash = ?db.getBlockHash(h.number)
        oldHeader = ?db.getBlockHeader(oldHash)
      for txHash in db.getBlockTransactionHashes(oldHeader):
        db.removeTransactionFromCanonicalChain(txHash)
        # TODO re-add txn to internal pending pool (only if local sender)

    for h in newCanonicalHeaders:
      # TODO don't recompute block hash
      db.addBlockNumberToHashLookup(h.number, h.blockHash)

  let canonicalHeadHash = canonicalHeadHashKey()
  db.ctx.getKvt.put(canonicalHeadHash.toOpenArray, rlp.encode(headerHash)).isOkOr:
    return err($$error)
  ok()

proc markCanonicalChain(
    db: CoreDbRef;
    header: Header;
    headerHash: Hash32;
      ): Result[void, string] =
  ## mark this chain as canonical by adding block number to hash lookup
  ## down to forking point
  const
    info = "markCanonicalChain()"
  var
    currHash = headerHash
    currHeader = header

  # mark current header as canonical
  let
    kvt = db.ctx.getKvt()
    key = blockNumberToHashKey(currHeader.number)
  kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
    return err($$error)

  # it is a genesis block, done
  if currHeader.parentHash == default(Hash32):
    return ok()

  # mark ancestor blocks as canonical too
  currHash = currHeader.parentHash
  currHeader = ?db.getBlockHeader(currHeader.parentHash)

  template rlpDecodeOrZero(data: openArray[byte]): Hash32 =
    try:
      rlp.decode(data, Hash32)
    except RlpError as exc:
      warn info, key, error=exc.msg
      default(Hash32)

  while currHash != default(Hash32):
    let key = blockNumberToHashKey(currHeader.number)
    let data = kvt.getOrEmpty(key.toOpenArray).valueOr:
      return err($$error)
    if data.len == 0:
      # not marked, mark it
      kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
        return err($$error)
    elif rlpDecodeOrZero(data) != currHash:
      # replace prev chain
      kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
        return err($$error)
    else:
      # forking point, done
      break

    if currHeader.parentHash == default(Hash32):
      break

    currHash = currHeader.parentHash
    currHeader = ?db.getBlockHeader(currHeader.parentHash)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getSavedStateBlockNumber*(
    db: CoreDbRef;
      ): BlockNumber =
  ## Returns the block number registered when the database was last time
  ## updated, or `BlockNumber(0)` if there was no update found.
  ##
  db.stateBlockNumber()

proc getBlockHeader*(
    db: CoreDbRef;
    blockHash: Hash32;
      ): Result[Header, string] =
  const info = "getBlockHeader()"
  let data = db.ctx.getKvt().get(genericHashKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn info, blockHash, error=($$error)
    return err("No block with hash " & $blockHash)

  wrapRlpException info:
    return ok(rlp.decode(data, Header))

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Result[Header, string] =
  ## Returns the block header with the given number in the canonical chain.
  let blockHash = ?db.getBlockHash(n)
  db.getBlockHeader(blockHash)

proc getHash(
    db: CoreDbRef;
    key: DbKey;
      ): Result[Hash32, string] =
  const info = "getHash()"
  let data = db.ctx.getKvt().get(key.toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn info, key, error=($$error)
    return err($$error)

  wrapRlpException info:
    return ok(rlp.decode(data, Hash32))

proc getCanonicalHeaderHash*(db: CoreDbRef): Result[Hash32, string] =
  db.getHash(canonicalHeadHashKey())

proc getCanonicalHead*(
    db: CoreDbRef;
      ): Result[Header, string] =
  let headHash = ?db.getCanonicalHeaderHash()
  db.getBlockHeader(headHash)

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Result[Hash32, string] =
  ## Return the block hash for the given block number.
  db.getHash(blockNumberToHashKey(n))

proc getScore*(
    db: CoreDbRef;
    blockHash: Hash32;
      ): Opt[UInt256] =
  const info = "getScore()"
  let data = db.ctx.getKvt()
               .get(blockHashToScoreKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn info, blockHash, error=($$error)
    return Opt.none(UInt256)
  try:
    Opt.some(rlp.decode(data, UInt256))
  except RlpError as exc:
    warn info, data = data.toHex(), error=exc.msg
    Opt.none(UInt256)

proc setScore*(db: CoreDbRef; blockHash: Hash32, score: UInt256) =
  ## for testing purpose
  let scoreKey = blockHashToScoreKey blockHash
  db.ctx.getKvt.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    warn "setScore()", scoreKey, error=($$error)
    return

proc headTotalDifficulty*(
    db: CoreDbRef;
      ): UInt256 =
  let blockHash = db.getCanonicalHeaderHash().valueOr:
    return 0.u256

  db.getScore(blockHash).valueOr(0.u256)

proc getAncestorsHashes*(
    db: CoreDbRef;
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
    db: CoreDbRef; blockNumber: BlockNumber, blockHash: Hash32) =
  let blockNumberKey = blockNumberToHashKey(blockNumber)
  db.ctx.getKvt.put(blockNumberKey.toOpenArray, rlp.encode(blockHash)).isOkOr:
    warn "addBlockNumberToHashLookup", blockNumberKey, error=($$error)

proc persistTransactions*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
    txRoot: Hash32;
    transactions: openArray[Transaction];
      ) =
  const
    info = "persistTransactions()"

  if transactions.len == 0:
    return

  let kvt = db.ctx.getKvt()
  for idx, tx in transactions:
    let
      encodedTx = rlp.encode(tx)
      txHash = keccak256(encodedTx)
      blockKey = transactionHashToBlockKey(txHash)
      txKey = TransactionKey(blockNumber: blockNumber, index: idx.uint)
      key = hashIndexKey(txRoot, idx.uint16)
    kvt.put(key, encodedTx).isOkOr:
      warn info, idx, error=($$error)
      return
    kvt.put(blockKey.toOpenArray, rlp.encode(txKey)).isOkOr:
      trace info, blockKey, error=($$error)
      return

proc forgetHistory*(
    db: CoreDbRef;
    blockNum: BlockNumber;
      ): bool =
  ## Remove all data related to the block number argument `num`. This function
  ## returns `true`, if some history was available and deleted.
  let blockHash = db.getBlockHash(blockNum).valueOr:
    return false

  let kvt = db.ctx.getKvt()
  # delete blockNum->blockHash
  discard kvt.del(blockNumberToHashKey(blockNum).toOpenArray)
  # delete blockHash->header, stateRoot->blockNum
  discard kvt.del(genericHashKey(blockHash).toOpenArray)
  true

proc getTransactionByIndex*(
    db: CoreDbRef;
    txRoot: Hash32;
    txIndex: uint16;
      ): Result[Transaction, string] =
  const
    info = "getTransaction()"

  let kvt = db.ctx.getKvt()
  let key = hashIndexKey(txRoot, txIndex)
  let txData = kvt.getOrEmpty(key).valueOr:
    return err($$error)
  if txData.len == 0:
    return err("tx data is empty for root=" & $txRoot & " and index=" & $txIndex)

  wrapRlpException info:
    return ok(rlp.decode(txData, Transaction))

proc getTransactionCount*(
    db: CoreDbRef;
    txRoot: Hash32;
      ): int =
  const
    info = "getTransactionCount()"

  let kvt = db.ctx.getKvt()
  var txCount = 0'u16
  while true:
    let key = hashIndexKey(txRoot, txCount)
    let yes = kvt.hasKeyRc(key).valueOr:
      warn info, txRoot, key, error=($$error)
      return 0
    if yes:
      inc txCount
    else:
      return txCount.int

  doAssert(false, "unreachable")

proc getUnclesCount*(
    db: CoreDbRef;
    ommersHash: Hash32;
      ): Result[int, string] =
  const info = "getUnclesCount()"
  if ommersHash == EMPTY_UNCLE_HASH:
    return ok(0)

  wrapRlpException info:
    let encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.ctx.getKvt().get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn info, ommersHash, error=($$error)
        return ok(0)
    return ok(rlpFromBytes(encodedUncles).listLen)

proc getUncles*(
    db: CoreDbRef;
    ommersHash: Hash32;
      ): Result[seq[Header], string] =
  const info = "getUncles()"
  if ommersHash != EMPTY_UNCLE_HASH:
    return ok(default(seq[Header]))

  wrapRlpException info:
    let  encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.ctx.getKvt().get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn info, ommersHash, error=($$error)
        return ok(default(seq[Header]))
    return ok(rlp.decode(encodedUncles, seq[Header]))

proc persistWithdrawals*(
    db: CoreDbRef;
    withdrawalsRoot: Hash32;
    withdrawals: openArray[Withdrawal];
      ) =
  const info = "persistWithdrawals()"
  if withdrawals.len == 0:
    return
  let kvt = db.ctx.getKvt()
  for idx, wd in withdrawals:
    let key = hashIndexKey(withdrawalsRoot, idx.uint16)
    kvt.put(key, rlp.encode(wd)).isOkOr:
      warn info, idx, error=($$error)
      return

proc getWithdrawals*(
    db: CoreDbRef;
    withdrawalsRoot: Hash32
      ): Result[seq[Withdrawal], string] =
  wrapRlpException "getWithdrawals":
    var res: seq[Withdrawal]
    for wd in db.getWithdrawals(withdrawalsRoot):
      res.add(wd)
    return ok(res)

proc getTransactions*(
    db: CoreDbRef;
    txRoot: Hash32
      ): Result[seq[Transaction], string] =
  wrapRlpException "getTransactions":
    var res: seq[Transaction]
    for encodedTx in db.getBlockTransactionData(txRoot):
      res.add(rlp.decode(encodedTx, Transaction))
    return ok(res)

proc getBlockBody*(
    db: CoreDbRef;
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
    db: CoreDbRef;
    blockHash: Hash32;
      ): Result[BlockBody, string] =
  let header = ?db.getBlockHeader(blockHash)
  db.getBlockBody(header)

proc getEthBlock*(
    db: CoreDbRef;
    hash: Hash32;
      ): Result[EthBlock, string] =
  var
    header = ?db.getBlockHeader(hash)
    blockBody = ?db.getBlockBody(hash)
  ok(EthBlock.init(move(header), move(blockBody)))

proc getEthBlock*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
      ): Result[EthBlock, string] =
  var
    header = ?db.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = ?db.getBlockBody(headerHash)
  ok(EthBlock.init(move(header), move(blockBody)))


proc getUncleHashes*(
    db: CoreDbRef;
    blockHashes: openArray[Hash32];
      ): Result[seq[Hash32], string] =
  var res: seq[Hash32]
  for blockHash in blockHashes:
    let body = ?db.getBlockBody(blockHash)
    res &= body.uncles.mapIt(it.rlpHash)
  ok(res)

proc getUncleHashes*(
    db: CoreDbRef;
    header: Header;
      ): Result[seq[Hash32], string] =
  if header.ommersHash != EMPTY_UNCLE_HASH:
    return ok(default(seq[Hash32]))

  wrapRlpException "getUncleHashes":
    let
      key = genericHashKey(header.ommersHash)
      encodedUncles = db.ctx.getKvt().get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn "getUncleHashes()", ommersHash=header.ommersHash, error=($$error)
        return ok(default(seq[Hash32]))
    return ok(rlp.decode(encodedUncles, seq[Header]).mapIt(it.rlpHash))

proc getTransactionKey*(
    db: CoreDbRef;
    transactionHash: Hash32;
      ): Result[TransactionKey, string] =
  wrapRlpException "getTransactionKey":
    let
      txKey = transactionHashToBlockKey(transactionHash)
      tx = db.ctx.getKvt().get(txKey.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn "getTransactionKey()", transactionHash, error=($$error)
        return ok(default(TransactionKey))
    return ok(rlp.decode(tx, TransactionKey))

proc headerExists*(db: CoreDbRef; blockHash: Hash32): bool =
  ## Returns True if the header with the given block hash is in our DB.
  db.ctx.getKvt().hasKeyRc(genericHashKey(blockHash).toOpenArray).valueOr:
    warn "headerExists()", blockHash, error=($$error)
    return false
  # => true/false

proc setHead*(
    db: CoreDbRef;
    blockHash: Hash32;
      ): Result[void, string] =
  let header = ?db.getBlockHeader(blockHash)
  ?db.markCanonicalChain(header, blockHash)

  let canonicalHeadHash = canonicalHeadHashKey()
  db.ctx.getKvt.put(canonicalHeadHash.toOpenArray, rlp.encode(blockHash)).isOkOr:
    return err($$error)
  ok()

proc setHead*(
    db: CoreDbRef;
    header: Header;
    writeHeader = false;
      ): Result[void, string] =
  var headerHash = rlpHash(header)
  let kvt = db.ctx.getKvt()
  if writeHeader:
    kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header)).isOkOr:
      return err($$error)
  ?db.markCanonicalChain(header, headerHash)
  let canonicalHeadHash = canonicalHeadHashKey()
  kvt.put(canonicalHeadHash.toOpenArray, rlp.encode(headerHash)).isOkOr:
    return err($$error)
  ok()

proc persistReceipts*(
    db: CoreDbRef;
    receiptsRoot: Hash32;
    receipts: openArray[Receipt];
      ) =
  const info = "persistReceipts()"
  if receipts.len == 0:
    return

  let kvt = db.ctx.getKvt()
  for idx, rec in receipts:
    let key = hashIndexKey(receiptsRoot, idx.uint16)
    kvt.put(key, rlp.encode(rec)).isOkOr:
      warn info, idx, error=($$error)

proc getReceipts*(
    db: CoreDbRef;
    receiptsRoot: Hash32;
      ): Result[seq[Receipt], string] =
  wrapRlpException "getReceipts":
    var receipts = newSeq[Receipt]()
    for r in db.getReceipts(receiptsRoot):
      receipts.add(r)
    return ok(receipts)

proc persistScore*(
    db: CoreDbRef;
    blockHash: Hash32;
    score: UInt256
      ): Result[void, string] =
  const
    info = "persistScore"
  let
    kvt = db.ctx.getKvt()
    scoreKey = blockHashToScoreKey(blockHash)
  kvt.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    return err(info & ": " & $$error)
  ok()

proc persistHeader*(
    db: CoreDbRef;
    blockHash: Hash32;
    header: Header;
    startOfHistory = GENESIS_PARENT_HASH;
      ): Result[void, string] =
  const
    info = "persistHeader"
  let
    kvt = db.ctx.getKvt()
    isStartOfHistory = header.parentHash == startOfHistory

  if not isStartOfHistory and not db.headerExists(header.parentHash):
    return err(info & ": parent header missing number " & $header.number)

  kvt.put(genericHashKey(blockHash).toOpenArray, rlp.encode(header)).isOkOr:
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

proc persistHeader*(
    db: CoreDbRef;
    blockHash: Hash32;
    header: Header;
    forceCanonical: bool;
    startOfHistory = GENESIS_PARENT_HASH;
      ): Result[void, string] =
  ?db.persistHeader(blockHash, header, startOfHistory)

  if not forceCanonical and header.parentHash != startOfHistory:
    let
      canonicalHash = ?db.getCanonicalHeaderHash()
      canonScore = db.getScore(canonicalHash).valueOr:
        return err("cannot load canon score")
      # TODO no need to load score from database _really_, but this code is
      #      hopefully going away soon
      score = db.getScore(blockHash).valueOr:
        return err("cannot load score")
    if score <= canonScore:
      return err("score >= canonScore")

  db.setAsCanonicalChainHead(blockHash, header)

proc persistHeader*(
    db: CoreDbRef;
    header: Header;
    forceCanonical: bool;
    startOfHistory = GENESIS_PARENT_HASH;
      ): Result[void, string] =
  let
    blockHash = header.blockHash
  db.persistHeader(blockHash, header, forceCanonical, startOfHistory)

proc persistUncles*(db: CoreDbRef, uncles: openArray[Header]): Hash32 =
  ## Persists the list of uncles to the database.
  ## Returns the uncles hash.
  let enc = rlp.encode(uncles)
  result = keccak256(enc)
  db.ctx.getKvt.put(genericHashKey(result).toOpenArray, enc).isOkOr:
    warn "persistUncles()", unclesHash=result, error=($$error)
    return EMPTY_ROOT_HASH


proc safeHeaderHash*(db: CoreDbRef): Hash32 =
  db.getHash(safeHashKey()).valueOr(default(Hash32))

proc safeHeaderHash*(db: CoreDbRef, headerHash: Hash32) =
  let safeHashKey = safeHashKey()
  db.ctx.getKvt.put(safeHashKey.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn "safeHeaderHash()", safeHashKey, error=($$error)
    return

proc finalizedHeaderHash*(
    db: CoreDbRef;
      ): Hash32 =
  db.getHash(finalizedHashKey()).valueOr(default(Hash32))

proc finalizedHeaderHash*(db: CoreDbRef, headerHash: Hash32) =
  let finalizedHashKey = finalizedHashKey()
  db.ctx.getKvt.put(finalizedHashKey.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn "finalizedHeaderHash()", finalizedHashKey, error=($$error)
    return

proc safeHeader*(
    db: CoreDbRef;
      ): Result[Header, string] =
  db.getBlockHeader(db.safeHeaderHash)

proc finalizedHeader*(
    db: CoreDbRef;
      ): Result[Header, string] =
  db.getBlockHeader(db.finalizedHeaderHash)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
