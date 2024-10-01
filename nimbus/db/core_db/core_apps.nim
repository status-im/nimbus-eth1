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

{.push raises: [].}

import
  std/[algorithm, sequtils],
  chronicles,
  eth/[common, rlp],
  stew/byteutils,
  "../.."/[errors, constants],
  ".."/[aristo, storage_types],
  "."/base

logScope:
  topics = "core_db"

type
  TransactionKey = tuple
    blockNumber: BlockNumber
    index: uint

# ------------------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------------------

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var Header;
      ): bool
      {.gcsafe.}

proc getBlockHeader*(
    db: CoreDbRef,
    blockHash: Hash32;
      ): Header
      {.gcsafe, raises: [BlockNotFound].}

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var Hash32;
      ): bool
      {.gcsafe.}

proc addBlockNumberToHashLookup*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
    blockHash: Hash32;
      ) {.gcsafe.}

proc getBlockHeader*(
    db: CoreDbRef;
    blockHash: Hash32;
    output: var Header;
      ): bool
      {.gcsafe.}

proc getCanonicalHeaderHash*(db: CoreDbRef): Opt[Hash32] {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template discardRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    warn info, error=($e.name), err=e.msg, errName=e.name

# ------------------------------------------------------------------------------
# Private iterators
# ------------------------------------------------------------------------------

iterator findNewAncestors(
    db: CoreDbRef;
    header: Header;
      ): Header =
  ## Returns the chain leading up from the given header until the first
  ## ancestor it has in common with our canonical chain.
  var h = header
  var orig: Header
  while true:
    if db.getBlockHeader(h.number, orig) and orig.rlpHash == h.rlpHash:
      break

    yield h

    if h.parentHash == GENESIS_PARENT_HASH:
      break
    else:
      if not db.getBlockHeader(h.parentHash, h):
        warn "findNewAncestors(): Could not find parent while iterating",
          hash = h.parentHash
        break

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
      ) =
  ## Sets the header as the canonical chain HEAD.
  const info = "setAsCanonicalChainHead()"

  # TODO This code handles reorgs - this should be moved elsewhere because we'll
  #      be handling reorgs mainly in-memory
  if header.number == 0 or
      db.getCanonicalHeaderHash().valueOr(default(Hash32)) != header.parentHash:
    var newCanonicalHeaders = sequtils.toSeq(db.findNewAncestors(header))
    reverse(newCanonicalHeaders)
    for h in newCanonicalHeaders:
      var oldHash: Hash32
      if not db.getBlockHash(h.number, oldHash):
        break

      try:
        let oldHeader = db.getBlockHeader(oldHash)
        for txHash in db.getBlockTransactionHashes(oldHeader):
          db.removeTransactionFromCanonicalChain(txHash)
          # TODO re-add txn to internal pending pool (only if local sender)
      except BlockNotFound:
        warn info & ": Could not load old header", oldHash

    for h in newCanonicalHeaders:
      # TODO don't recompute block hash
      db.addBlockNumberToHashLookup(h.number, h.blockHash)

  let canonicalHeadHash = canonicalHeadHashKey()
  db.ctx.getKvt.put(canonicalHeadHash.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn info, canonicalHeadHash, error=($$error)

proc markCanonicalChain(
    db: CoreDbRef;
    header: Header;
    headerHash: Hash32;
      ): bool =
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
    warn info, key, error=($$error)
    return false

  # it is a genesis block, done
  if currHeader.parentHash == default(Hash32):
    return true

  # mark ancestor blocks as canonical too
  currHash = currHeader.parentHash
  if not db.getBlockHeader(currHeader.parentHash, currHeader):
    return false

  template rlpDecodeOrZero(data: openArray[byte]): Hash32 =
    try:
      rlp.decode(data, Hash32)
    except RlpError as exc:
      warn info, key, error=exc.msg
      default(Hash32)

  while currHash != default(Hash32):
    let key = blockNumberToHashKey(currHeader.number)
    let data = kvt.getOrEmpty(key.toOpenArray).valueOr:
      warn info, key, error=($$error)
      return false
    if data.len == 0:
      # not marked, mark it
      kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
        warn info, key, error=($$error)
    elif rlpDecodeOrZero(data) != currHash:
      # replace prev chain
      kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
        warn info, key, error=($$error)
    else:
      # forking point, done
      break

    if currHeader.parentHash == default(Hash32):
      break

    currHash = currHeader.parentHash
    if not db.getBlockHeader(currHeader.parentHash, currHeader):
      return false

  return true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getSavedStateBlockNumber*(
    db: CoreDbRef;
      ): BlockNumber =
  ## Returns the block number registered when the database was last time
  ## updated, or `BlockNumber(0)` if there was no updata found.
  ##
  db.stateBlockNumber()

proc getBlockHeader*(
    db: CoreDbRef;
    blockHash: Hash32;
    output: var Header;
      ): bool =
  const info = "getBlockHeader()"
  let data = db.ctx.getKvt().get(genericHashKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn info, blockHash, error=($$error)
    return false

  discardRlpException info:
    output = rlp.decode(data, Header)
    return true

proc getBlockHeader*(
    db: CoreDbRef,
    blockHash: Hash32;
      ): Header =
  ## Returns the requested block header as specified by block hash.
  ##
  ## Raises BlockNotFound if it is not present in the db.
  if not db.getBlockHeader(blockHash, result):
    raise newException(
      BlockNotFound, "No block with hash " & blockHash.data.toHex)

proc getHash(
    db: CoreDbRef;
    key: DbKey;
      ): Opt[Hash32] =
  const info = "getHash()"
  let data = db.ctx.getKvt().get(key.toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn info, key, error=($$error)
    return Opt.none(Hash32)

  try:
    Opt.some(rlp.decode(data, Hash32))
  except RlpError as exc:
    warn info, key, error=exc.msg
    Opt.none(Hash32)

proc getCanonicalHeaderHash*(db: CoreDbRef): Opt[Hash32] =
  db.getHash(canonicalHeadHashKey())

proc getCanonicalHead*(
    db: CoreDbRef;
    output: var Header;
      ): bool =
  let headHash = db.getCanonicalHeaderHash().valueOr:
    return false
  discardRlpException "getCanonicalHead()":
    if db.getBlockHeader(headHash, output):
      return true

proc getCanonicalHead*(
    db: CoreDbRef;
      ): Header
      {.gcsafe, raises: [EVMError].} =
  if not db.getCanonicalHead result:
    raise newException(
      CanonicalHeadNotFound, "No canonical head set for this chain")

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var Hash32;
      ): bool =
  ## Return the block hash for the given block number.
  output = db.getHash(blockNumberToHashKey(n)).valueOr:
    return false
  true

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Hash32
      {.gcsafe, raises: [BlockNotFound].} =
  ## Return the block hash for the given block number.
  if not db.getBlockHash(n, result):
    raise newException(BlockNotFound, "No block hash for number " & $n)

proc getHeadBlockHash*(db: CoreDbRef): Hash32 =
  db.getHash(canonicalHeadHashKey()).valueOr(default(Hash32))

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var Header;
      ): bool =
  ## Returns the block header with the given number in the canonical chain.
  var blockHash: Hash32
  if db.getBlockHash(n, blockHash):
    result = db.getBlockHeader(blockHash, output)

proc getBlockHeaderWithHash*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Opt[(Header, Hash32)] =
  ## Returns the block header and its hash, with the given number in the
  ## canonical chain. Hash is returned to avoid recomputing it
  var hash: Hash32
  if db.getBlockHash(n, hash):
    # Note: this will throw if header is not present.
    var header: Header
    if db.getBlockHeader(hash, header):
      return Opt.some((header, hash))
    else:
      # this should not happen, but if it happen lets fail laudly as this means
      # something is super wrong
      raiseAssert("Corrupted database. Mapping number->hash present, without header in database")
  else:
    return Opt.none((Header, Hash32))

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Header
      {.raises: [BlockNotFound].} =
  ## Returns the block header with the given number in the canonical chain.
  ## Raises BlockNotFound error if the block is not in the DB.
  db.getBlockHeader(db.getBlockHash(n))

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

proc getTd*(db: CoreDbRef; blockHash: Hash32, td: var UInt256): bool =
  td = db.getScore(blockHash).valueOr:
    return false
  true

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
      ): seq[Hash32]
      {.gcsafe, raises: [BlockNotFound].} =
  var ancestorCount = min(header.number, limit)
  var h = header

  result = newSeq[Hash32](ancestorCount)
  while ancestorCount > 0:
    h = db.getBlockHeader(h.parentHash)
    result[ancestorCount - 1] = h.rlpHash
    dec ancestorCount

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
      txKey: TransactionKey = (blockNumber, idx.uint)
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
  var blockHash: Hash32
  if db.getBlockHash(blockNum, blockHash):
    let kvt = db.ctx.getKvt()
    # delete blockNum->blockHash
    discard kvt.del(blockNumberToHashKey(blockNum).toOpenArray)
    result = true

    var header: Header
    if db.getBlockHeader(blockHash, header):
      # delete blockHash->header, stateRoot->blockNum
      discard kvt.del(genericHashKey(blockHash).toOpenArray)

proc getTransactionByIndex*(
    db: CoreDbRef;
    txRoot: Hash32;
    txIndex: uint16;
    res: var Transaction;
      ): bool =
  const
    info = "getTransaction()"

  let kvt = db.ctx.getKvt()
  let key = hashIndexKey(txRoot, txIndex)
  let txData = kvt.getOrEmpty(key).valueOr:
    warn info, txRoot, key, error=($$error)
    return false
  if txData.len == 0:
    return false

  try:
    res = rlp.decode(txData, Transaction)
  except RlpError as e:
    warn info, txRoot, err=e.msg, errName=e.name
    return false
  true

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
      ): int
      {.gcsafe, raises: [RlpError].} =
  const info = "getUnclesCount()"
  if ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.ctx.getKvt().get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn info, ommersHash, error=($$error)
        return 0
    return rlpFromBytes(encodedUncles).listLen

proc getUncles*(
    db: CoreDbRef;
    ommersHash: Hash32;
      ): seq[Header]
      {.gcsafe, raises: [RlpError].} =
  const info = "getUncles()"
  if ommersHash != EMPTY_UNCLE_HASH:
    let  encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.ctx.getKvt().get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn info, ommersHash, error=($$error)
        return @[]
    return rlp.decode(encodedUncles, seq[Header])

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
    withdrawalsRoot: Hash32;
      ): seq[Withdrawal]
      {.gcsafe, raises: [RlpError].} =
  for wd in db.getWithdrawals(withdrawalsRoot):
    result.add(wd)

proc getTransactions*(
    db: CoreDbRef;
    txRoot: Hash32;
    output: var seq[Transaction])
      {.gcsafe, raises: [RlpError].} =
  for encodedTx in db.getBlockTransactionData(txRoot):
    output.add(rlp.decode(encodedTx, Transaction))

proc getTransactions*(
    db: CoreDbRef;
    txRoot: Hash32;
    ): seq[Transaction]
      {.gcsafe, raises: [RlpError].} =
  db.getTransactions(txRoot, result)

proc getBlockBody*(
    db: CoreDbRef;
    header: Header;
    output: var BlockBody;
      ): bool =
  try:
    output.transactions = db.getTransactions(header.txRoot)
    output.uncles = db.getUncles(header.ommersHash)

    if header.withdrawalsRoot.isSome:
      output.withdrawals = Opt.some(db.getWithdrawals(header.withdrawalsRoot.get))
    true
  except RlpError:
    false

proc getBlockBody*(
    db: CoreDbRef;
    blockHash: Hash32;
    output: var BlockBody;
      ): bool =
  var header: Header
  if db.getBlockHeader(blockHash, header):
    return db.getBlockBody(header, output)

proc getBlockBody*(
    db: CoreDbRef;
    hash: Hash32;
      ): BlockBody
      {.gcsafe, raises: [BlockNotFound].} =
  if not db.getBlockBody(hash, result):
    raise newException(BlockNotFound, "Error when retrieving block body")

proc getEthBlock*(
    db: CoreDbRef;
    hash: Hash32;
      ): EthBlock
      {.gcsafe, raises: [BlockNotFound].} =
  var
    header = db.getBlockHeader(hash)
    blockBody = db.getBlockBody(hash)
  EthBlock.init(move(header), move(blockBody))

proc getEthBlock*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
      ): EthBlock
      {.gcsafe, raises: [BlockNotFound].} =
  var
    header = db.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = db.getBlockBody(headerHash)
  EthBlock.init(move(header), move(blockBody))

proc getUncleHashes*(
    db: CoreDbRef;
    blockHashes: openArray[Hash32];
      ): seq[Hash32]
      {.gcsafe, raises: [BlockNotFound].} =
  for blockHash in blockHashes:
    result &= db.getBlockBody(blockHash).uncles.mapIt(it.rlpHash)

proc getUncleHashes*(
    db: CoreDbRef;
    header: Header;
      ): seq[Hash32]
      {.gcsafe, raises: [RlpError].} =
  if header.ommersHash != EMPTY_UNCLE_HASH:
    let
      key = genericHashKey(header.ommersHash)
      encodedUncles = db.ctx.getKvt().get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn "getUncleHashes()", ommersHash=header.ommersHash, error=($$error)
        return @[]
    return rlp.decode(encodedUncles, seq[Header]).mapIt(it.rlpHash)

proc getTransactionKey*(
    db: CoreDbRef;
    transactionHash: Hash32;
      ): tuple[blockNumber: BlockNumber, index: uint64]
      {.gcsafe, raises: [RlpError].} =
  let
    txKey = transactionHashToBlockKey(transactionHash)
    tx = db.ctx.getKvt().get(txKey.toOpenArray).valueOr:
      if error.error == KvtNotFound:
        warn "getTransactionKey()", transactionHash, error=($$error)
      return (0.BlockNumber, 0)
  let key = rlp.decode(tx, TransactionKey)
  (key.blockNumber, key.index.uint64)

proc headerExists*(db: CoreDbRef; blockHash: Hash32): bool =
  ## Returns True if the header with the given block hash is in our DB.
  db.ctx.getKvt().hasKeyRc(genericHashKey(blockHash).toOpenArray).valueOr:
    warn "headerExists()", blockHash, error=($$error)
    return false
  # => true/false

proc setHead*(
    db: CoreDbRef;
    blockHash: Hash32;
      ): bool =
  var header: Header
  if not db.getBlockHeader(blockHash, header):
    return false

  if not db.markCanonicalChain(header, blockHash):
    return false

  let canonicalHeadHash = canonicalHeadHashKey()
  db.ctx.getKvt.put(canonicalHeadHash.toOpenArray, rlp.encode(blockHash)).isOkOr:
    warn "setHead()", canonicalHeadHash, error=($$error)
  return true

proc setHead*(
    db: CoreDbRef;
    header: Header;
    writeHeader = false;
      ): bool =
  const info = "setHead()"
  var headerHash = rlpHash(header)
  let kvt = db.ctx.getKvt()
  if writeHeader:
    kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header)).isOkOr:
      warn info, headerHash, error=($$error)
      return false
  if not db.markCanonicalChain(header, headerHash):
    return false
  let canonicalHeadHash = canonicalHeadHashKey()
  kvt.put(canonicalHeadHash.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn info, canonicalHeadHash, error=($$error)
    return false
  true

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
      ): seq[Receipt]
      {.gcsafe, raises: [RlpError].} =
  var receipts = newSeq[Receipt]()
  for r in db.getReceipts(receiptsRoot):
    receipts.add(r)
  return receipts

proc persistScore*(
    db: CoreDbRef;
    blockHash: Hash32;
    score: UInt256
      ): bool =
  const
    info = "persistScore"
  let
    kvt = db.ctx.getKvt()
    scoreKey = blockHashToScoreKey(blockHash)
  kvt.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    warn info, scoreKey, error=($$error)
    return
  true

proc persistHeader*(
    db: CoreDbRef;
    blockHash: Hash32;
    header: Header;
    startOfHistory = GENESIS_PARENT_HASH;
      ): bool =
  const
    info = "persistHeader"
  let
    kvt = db.ctx.getKvt()
    isStartOfHistory = header.parentHash == startOfHistory

  if not isStartOfHistory and not db.headerExists(header.parentHash):
    warn info & ": parent header missing", blockNumber=header.number
    return false

  kvt.put(genericHashKey(blockHash).toOpenArray, rlp.encode(header)).isOkOr:
    warn info, blockHash, blockNumber=header.number, error=($$error)
    return false

  let
    parentScore = if isStartOfHistory:
      0.u256
    else:
      db.getScore(header.parentHash).valueOr:
        # TODO it's slightly wrong to fail here and leave the block in the db,
        #      but this code is going away soon enough
        return false

    score = parentScore + header.difficulty
  # After EIP-3675, difficulty is set to 0 but we still save the score for
  # each block to simplify totalDifficulty reporting
  # TODO get rid of this and store a single value
  if not db.persistScore(blockHash, score):
    return false

  db.addBlockNumberToHashLookup(header.number, blockHash)
  true

proc persistHeader*(
    db: CoreDbRef;
    blockHash: Hash32;
    header: Header;
    forceCanonical: bool;
    startOfHistory = GENESIS_PARENT_HASH;
      ): bool =
  if not db.persistHeader(blockHash, header, startOfHistory):
    return false

  if not forceCanonical and header.parentHash != startOfHistory:
    let
      canonicalHash = db.getCanonicalHeaderHash().valueOr:
        return false
      canonScore = db.getScore(canonicalHash).valueOr:
        return false
      # TODO no need to load score from database _really_, but this code is
      #      hopefully going away soon
      score = db.getScore(blockHash).valueOr:
        return false
    if score <= canonScore:
      return true

  db.setAsCanonicalChainHead(blockHash, header)
  true

proc persistHeader*(
    db: CoreDbRef;
    header: Header;
    forceCanonical: bool;
    startOfHistory = GENESIS_PARENT_HASH;
      ): bool =
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
      ): Header
      {.gcsafe, raises: [BlockNotFound].} =
  db.getBlockHeader(db.safeHeaderHash)

proc finalizedHeader*(
    db: CoreDbRef;
      ): Header
      {.gcsafe, raises: [BlockNotFound].} =
  db.getBlockHeader(db.finalizedHeaderHash)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
