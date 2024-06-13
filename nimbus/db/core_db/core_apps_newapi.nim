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
  std/[algorithm, options, sequtils],
  chronicles,
  eth/[common, rlp],
  results,
  stew/byteutils,
  "../.."/[errors, constants],
  ".."/[aristo, storage_types],
  ./backend/aristo_db,
  "."/base

logScope:
  topics = "core_db-apps"

type
  TransactionKey = tuple
    blockNumber: BlockNumber
    index: int

const
  extraTraceMessages = false
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------------------

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var BlockHeader;
      ): bool
      {.gcsafe.}

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
      {.gcsafe.}

proc addBlockNumberToHashLookup*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
    blockHash: Hash256;
      ) {.gcsafe.}

proc getBlockHeader*(
    db: CoreDbRef;
    blockHash: Hash256;
    output: var BlockHeader;
      ): bool
      {.gcsafe.}

proc getCanonicalHeaderHash*(db: CoreDbRef): Opt[Hash256] {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Core apps " & info

template discardRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    warn logTxt info, error=($e.name), msg=e.msg

# ------------------------------------------------------------------------------
# Private iterators
# ------------------------------------------------------------------------------

iterator findNewAncestors(
    db: CoreDbRef;
    header: BlockHeader;
      ): BlockHeader =
  ## Returns the chain leading up from the given header until the first
  ## ancestor it has in common with our canonical chain.
  var h = header
  var orig: BlockHeader
  while true:
    if db.getBlockHeader(h.blockNumber, orig) and orig.rlpHash == h.rlpHash:
      break

    yield h

    if h.parentHash == GENESIS_PARENT_HASH:
      break
    else:
      if not db.getBlockHeader(h.parentHash, h):
        warn "Could not find parent while iterating", hash = h.parentHash
        break

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator getBlockTransactionData*(
    db: CoreDbRef;
    transactionRoot: Hash256;
      ): Blob =
  block body:
    if transactionRoot == EMPTY_ROOT_HASH:
      break body

    let
      ctx = db.ctx
      col = ctx.newColumn(CtTxs, transactionRoot).valueOr:
        warn logTxt "getBlockTransactionData()",
          transactionRoot, action="newColumn()", `error`=($$error)
        break body
      transactionDb = ctx.getMpt(col).valueOr:
        warn logTxt "getBlockTransactionData()", transactionRoot,
          action="newMpt()", col=($$col), error=($$error)
        break body
    var transactionIdx = 0
    while true:
      let transactionKey = rlp.encode(transactionIdx)
      let data = transactionDb.fetch(transactionKey).valueOr:
        if error.error != MptNotFound:
          warn logTxt "getBlockTransactionData()", transactionRoot,
            transactionKey, action="fetch()", error=($$error)
        break body
      yield data
      inc transactionIdx


iterator getBlockTransactions*(
    db: CoreDbRef;
    header: BlockHeader;
      ): Transaction =
  for encodedTx in db.getBlockTransactionData(header.txRoot):
    try:
      yield rlp.decode(encodedTx, Transaction)
    except RlpError as exc:
      warn "Cannot decode database transaction", data = toHex(encodedTx), error = exc.msg

iterator getBlockTransactionHashes*(
    db: CoreDbRef;
    blockHeader: BlockHeader;
      ): Hash256 =
  ## Returns an iterable of the transaction hashes from th block specified
  ## by the given block header.
  for encodedTx in db.getBlockTransactionData(blockHeader.txRoot):
    yield keccakHash(encodedTx)

iterator getWithdrawalsData*(
    db: CoreDbRef;
    withdrawalsRoot: Hash256;
      ): Blob =
  block body:
    if withdrawalsRoot == EMPTY_ROOT_HASH:
      break body

    let
      ctx = db.ctx
      col = ctx.newColumn(CtWithdrawals, withdrawalsRoot).valueOr:
        warn logTxt "getWithdrawalsData()",
          withdrawalsRoot, action="newColumn()", error=($$error)
        break body
      wddb = ctx.getMpt(col).valueOr:
        warn logTxt "getWithdrawalsData()",
          withdrawalsRoot, action="newMpt()", col=($$col), error=($$error)
        break body
    var idx = 0
    while true:
      let wdKey = rlp.encode(idx)
      let data = wddb.fetch(wdKey).valueOr:
        if error.error != MptNotFound:
          warn logTxt "getWithdrawalsData()",
            withdrawalsRoot, wdKey, action="fetch()", error=($$error)
        break body
      yield data
      inc idx


iterator getReceipts*(
    db: CoreDbRef;
    receiptRoot: Hash256;
      ): Receipt
      {.gcsafe, raises: [RlpError].} =
  block body:
    if receiptRoot == EMPTY_ROOT_HASH:
      break body

    let
      ctx = db.ctx
      col = ctx.newColumn(CtReceipts, receiptRoot).valueOr:
        warn logTxt "getWithdrawalsData()",
          receiptRoot, action="newColumn()", error=($$error)
        break body
      receiptDb = ctx.getMpt(col).valueOr:
        warn logTxt "getWithdrawalsData()",
          receiptRoot, action="getMpt()", col=($$col), error=($$error)
        break body
    var receiptIdx = 0
    while true:
      let receiptKey = rlp.encode(receiptIdx)
      let receiptData = receiptDb.fetch(receiptKey).valueOr:
        if error.error != MptNotFound:
          warn logTxt "getWithdrawalsData()",
            receiptRoot, receiptKey, action="hasKey()", error=($$error)
        break body
      yield rlp.decode(receiptData, Receipt)
      inc receiptIdx

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc removeTransactionFromCanonicalChain(
    db: CoreDbRef;
    transactionHash: Hash256;
      ) =
  ## Removes the transaction specified by the given hash from the canonical
  ## chain.
  db.newKvt.del(transactionHashToBlockKey(transactionHash).toOpenArray).isOkOr:
    warn logTxt "removeTransactionFromCanonicalChain()",
      transactionHash, action="del()", error=($$error)

proc setAsCanonicalChainHead(
    db: CoreDbRef;
    headerHash: Hash256;
    header: BlockHeader;
      ) =
  ## Sets the header as the canonical chain HEAD.

  # TODO This code handles reorgs - this should be moved elsewhere because we'll
  #      be handling reorgs mainly in-memory
  if header.blockNumber == 0 or
      db.getCanonicalHeaderHash().valueOr(Hash256()) != header.parentHash:
    var newCanonicalHeaders = sequtils.toSeq(db.findNewAncestors(header))
    reverse(newCanonicalHeaders)
    for h in newCanonicalHeaders:
      var oldHash: Hash256
      if not db.getBlockHash(h.blockNumber, oldHash):
        break

      try:
        let oldHeader = db.getBlockHeader(oldHash)
        for txHash in db.getBlockTransactionHashes(oldHeader):
          db.removeTransactionFromCanonicalChain(txHash)
          # TODO re-add txn to internal pending pool (only if local sender)
      except BlockNotFound:
        warn "Could not load old header", oldHash

    for h in newCanonicalHeaders:
      # TODO don't recompute block hash
      db.addBlockNumberToHashLookup(h.blockNumber, h.blockHash)

  let canonicalHeadHash = canonicalHeadHashKey()
  db.newKvt.put(canonicalHeadHash.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn logTxt "setAsCanonicalChainHead()",
      canonicalHeadHash, action="put()", error=($$error)

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
  let
    kvt = db.newKvt()
    key = blockNumberToHashKey(currHeader.blockNumber)
  kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
    warn logTxt "markCanonicalChain()", key, action="put()", error=($$error)
    return false

  # it is a genesis block, done
  if currHeader.parentHash == Hash256():
    return true

  # mark ancestor blocks as canonical too
  currHash = currHeader.parentHash
  if not db.getBlockHeader(currHeader.parentHash, currHeader):
    return false

  while currHash != Hash256():
    let key = blockNumberToHashKey(currHeader.blockNumber)
    let data = kvt.getOrEmpty(key.toOpenArray).valueOr:
      warn logTxt "markCanonicalChain()", key, action="get()", error=($$error)
      return false
    if data.len == 0:
      # not marked, mark it
      kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
        warn logTxt "markCanonicalChain()", key, action="put()", error=($$error)
    elif rlp.decode(data, Hash256) != currHash:
      # replace prev chain
      kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
        warn logTxt "markCanonicalChain()", key, action="put()", error=($$error)
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
  db.newKvt().hasKey(hash.data).valueOr:
    warn logTxt "exisis()", hash, action="hasKey()", error=($$error)
    return false

proc getSavedStateBlockNumber*(
    db: CoreDbRef;
    relax = false;
      ): BlockNumber =
  ## Returns the block number registered when the database was last time
  ## updated, or `BlockNumber(0)` if there was no updata found.
  ##
  ## This function verifies the state consistency of the database and throws
  ## an assert exception if that fails. So the function will only apply to a
  ## finalised (aka hashified) database state. For an an opportunistic use,
  ## the `relax` argument can be set `true` so this function also returns
  ## zero if the state consistency check fails.
  ##
  var header: BlockHeader
  let st = db.ctx.getMpt(CtGeneric).backend.toAristoSavedStateBlockNumber()
  if db.getBlockHeader(st.blockNumber, header):
    discard db.ctx.newColumn(CtAccounts,header.stateRoot).valueOr:
      if relax:
        return
      raiseAssert "getSavedStateBlockNumber(): state mismatch at " &
        "#" & $st.blockNumber
    return st.blockNumber

proc getBlockHeader*(
    db: CoreDbRef;
    blockHash: Hash256;
    output: var BlockHeader;
      ): bool =
  const info = "getBlockHeader()"
  let data = db.newKvt().get(genericHashKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn logTxt info, blockHash, action="get()", error=($$error)
    return false

  discardRlpException info:
    output = rlp.decode(data, BlockHeader)
    return true

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
      ): Opt[Hash256] =
  let data = db.newKvt().get(key.toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn logTxt "getHash()", key, action="get()", error=($$error)
    return Opt.none(Hash256)

  try:
    Opt.some(rlp.decode(data, Hash256))
  except RlpError as exc:
    warn logTxt "getHash()", key, action="rlp.decode()", error=exc.msg
    Opt.none(Hash256)

proc getCanonicalHeaderHash*(db: CoreDbRef): Opt[Hash256] =
  db.getHash(canonicalHeadHashKey())

proc getCanonicalHead*(
    db: CoreDbRef;
    output: var BlockHeader;
      ): bool =
  let headHash = db.getCanonicalHeaderHash().valueOr:
    return false
  discardRlpException "getCanonicalHead()":
    if db.getBlockHeader(headHash, output):
      return true

proc getCanonicalHead*(
    db: CoreDbRef;
      ): BlockHeader
      {.gcsafe, raises: [EVMError].} =
  if not db.getCanonicalHead result:
    raise newException(
      CanonicalHeadNotFound, "No canonical head set for this chain")

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var Hash256;
      ): bool =
  ## Return the block hash for the given block number.
  output = db.getHash(blockNumberToHashKey(n)).valueOr:
    return false
  true

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Hash256
      {.gcsafe, raises: [BlockNotFound].} =
  ## Return the block hash for the given block number.
  if not db.getBlockHash(n, result):
    raise newException(BlockNotFound, "No block hash for number " & $n)

proc getHeadBlockHash*(db: CoreDbRef): Hash256 =
  db.getHash(canonicalHeadHashKey()).valueOr(Hash256())

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
      ): Option[(BlockHeader, Hash256)] =
  ## Returns the block header and its hash, with the given number in the
  ## canonical chain. Hash is returned to avoid recomputing it
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
      {.raises: [BlockNotFound].} =
  ## Returns the block header with the given number in the canonical chain.
  ## Raises BlockNotFound error if the block is not in the DB.
  db.getBlockHeader(db.getBlockHash(n))

proc getScore*(
    db: CoreDbRef;
    blockHash: Hash256;
      ): Opt[UInt256] =
  let data = db.newKvt()
               .get(blockHashToScoreKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn logTxt "getScore()", blockHash, action="get()", error=($$error)
    return Opt.none(UInt256)
  try:
    Opt.some(rlp.decode(data, UInt256))
  except RlpError as exc:
    warn logTxt "getScore()", data = data.toHex(), error=exc.msg
    Opt.none(UInt256)

proc setScore*(db: CoreDbRef; blockHash: Hash256, score: UInt256) =
  ## for testing purpose
  let scoreKey = blockHashToScoreKey blockHash
  db.newKvt.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    warn logTxt "setScore()", scoreKey, action="put()", error=($$error)
    return

proc getTd*(db: CoreDbRef; blockHash: Hash256, td: var UInt256): bool =
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
    limit: UInt256;
    header: BlockHeader;
      ): seq[Hash256]
      {.gcsafe, raises: [BlockNotFound].} =
  var ancestorCount = min(header.blockNumber, limit).truncate(int)
  var h = header

  result = newSeq[Hash256](ancestorCount)
  while ancestorCount > 0:
    h = db.getBlockHeader(h.parentHash)
    result[ancestorCount - 1] = h.rlpHash
    dec ancestorCount

proc addBlockNumberToHashLookup*(
    db: CoreDbRef; blockNumber: BlockNumber, blockHash: Hash256) =
  let blockNumberKey = blockNumberToHashKey(blockNumber)
  db.newKvt.put(blockNumberKey.toOpenArray, rlp.encode(blockHash)).isOkOr:
    warn logTxt "addBlockNumberToHashLookup()",
      blockNumberKey, action="put()", error=($$error)

proc persistTransactions*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
    transactions: openArray[Transaction];
      ) =
  const
    info = "persistTransactions()"

  if transactions.len == 0:
    return

  let
    mpt = db.ctx.getMpt(CtTxs)
    kvt = db.newKvt()

  for idx, tx in transactions:
    let
      encodedKey = rlp.encode(idx)
      encodedTx = rlp.encode(tx)
      txHash = keccakHash(encodedTx)
      blockKey = transactionHashToBlockKey(txHash)
      txKey: TransactionKey = (blockNumber, idx)
    mpt.merge(encodedKey, encodedTx).isOkOr:
      warn logTxt info, idx, action="merge()", error=($$error)
      return
    kvt.put(blockKey.toOpenArray, rlp.encode(txKey)).isOkOr:
      trace logTxt info, blockKey, action="put()", error=($$error)
      return

proc forgetHistory*(
    db: CoreDbRef;
    blockNum: BlockNumber;
      ): bool =
  ## Remove all data related to the block number argument `num`. This function
  ## returns `true`, if some history was available and deleted.
  var blockHash: Hash256
  if db.getBlockHash(blockNum, blockHash):
    let kvt = db.newKvt()
    # delete blockNum->blockHash
    discard kvt.del(blockNumberToHashKey(blockNum).toOpenArray)
    result = true

    var header: BlockHeader
    if db.getBlockHeader(blockHash, header):
      # delete blockHash->header, stateRoot->blockNum
      discard kvt.del(genericHashKey(blockHash).toOpenArray)

proc getTransaction*(
    db: CoreDbRef;
    txRoot: Hash256;
    txIndex: int;
    res: var Transaction;
      ): bool =
  const
    info = "getTransaction()"
  let
    ctx = db.ctx
    col = ctx.newColumn(CtTxs, txRoot).valueOr:
      warn logTxt info, txRoot, action="newColumn()", error=($$error)
      return false
    mpt = ctx.getMpt(col).valueOr:
      warn logTxt info,
        txRoot, action="newMpt()", col=($$col), error=($$error)
      return false
    txData = mpt.fetch(rlp.encode(txIndex)).valueOr:
      if error.error != MptNotFound:
        warn logTxt info, txIndex, action="fetch()", error=($$error)
      return false
  try:
    res = rlp.decode(txData, Transaction)
  except RlpError as exc:
    warn logTxt info,
      txRoot, action="rlp.decode()", col=($$col), error=exc.msg
    return false
  true

proc getTransactionCount*(
    db: CoreDbRef;
    txRoot: Hash256;
      ): int =
  const
    info = "getTransactionCount()"
  let
    ctx = db.ctx
    col = ctx.newColumn(CtTxs, txRoot).valueOr:
      warn logTxt info, txRoot, action="newColumn()", error=($$error)
      return 0
    mpt = ctx.getMpt(col).valueOr:
      warn logTxt info, txRoot,
        action="newMpt()", col=($$col), error=($$error)
      return 0
  var txCount = 0
  while true:
    let hasPath = mpt.hasPath(rlp.encode(txCount)).valueOr:
      warn logTxt info, txCount, action="hasPath()", error=($$error)
      return 0
    if hasPath:
      inc txCount
    else:
      return txCount

  doAssert(false, "unreachable")

proc getUnclesCount*(
    db: CoreDbRef;
    ommersHash: Hash256;
      ): int
      {.gcsafe, raises: [RlpError].} =
  const info = "getUnclesCount()"
  if ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.newKvt().get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn logTxt info, ommersHash, action="get()", `error`=($$error)
        return 0
    return rlpFromBytes(encodedUncles).listLen

proc getUncles*(
    db: CoreDbRef;
    ommersHash: Hash256;
      ): seq[BlockHeader]
      {.gcsafe, raises: [RlpError].} =
  const info = "getUncles()"
  if ommersHash != EMPTY_UNCLE_HASH:
    let  encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.newKvt().get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn logTxt info, ommersHash, action="get()", `error`=($$error)
        return @[]
    return rlp.decode(encodedUncles, seq[BlockHeader])

proc persistWithdrawals*(
    db: CoreDbRef;
    withdrawals: openArray[Withdrawal];
      ) =
  const info = "persistWithdrawals()"
  if withdrawals.len == 0:
    return

  let mpt = db.ctx.getMpt(CtWithdrawals)
  for idx, wd in withdrawals:
    mpt.merge(rlp.encode(idx), rlp.encode(wd)).isOkOr:
      warn logTxt info, idx, action="merge()", error=($$error)
      return

proc getWithdrawals*(
    db: CoreDbRef;
    withdrawalsRoot: Hash256;
      ): seq[Withdrawal]
      {.gcsafe, raises: [RlpError].} =
  for encodedWd in db.getWithdrawalsData(withdrawalsRoot):
    result.add(rlp.decode(encodedWd, Withdrawal))

proc getTransactions*(
    db: CoreDbRef;
    txRoot: Hash256;
    output: var seq[Transaction])
      {.gcsafe, raises: [RlpError].} =
  for encodedTx in db.getBlockTransactionData(txRoot):
    output.add(rlp.decode(encodedTx, Transaction))

proc getTransactions*(
    db: CoreDbRef;
    txRoot: Hash256;
    ): seq[Transaction]
      {.gcsafe, raises: [RlpError].} =
  db.getTransactions(txRoot, result)

proc getBlockBody*(
    db: CoreDbRef;
    header: BlockHeader;
    output: var BlockBody;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  output.transactions = db.getTransactions(header.txRoot)
  output.uncles = db.getUncles(header.ommersHash)

  if header.withdrawalsRoot.isSome:
    output.withdrawals = some(db.getWithdrawals(header.withdrawalsRoot.get))

  true

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

proc getEthBlock*(
    db: CoreDbRef;
    hash: Hash256;
      ): EthBlock
      {.gcsafe, raises: [BlockNotFound, RlpError,ValueError].} =
  var
    header = db.getBlockHeader(hash)
    blockBody = db.getBlockBody(hash)
  EthBlock.init(move(header), move(blockBody))

proc getEthBlock*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
      ): EthBlock
      {.gcsafe, raises: [BlockNotFound, RlpError,ValueError].} =
  var
    header = db.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = db.getBlockBody(headerHash)
  EthBlock.init(move(header), move(blockBody))

proc getUncleHashes*(
    db: CoreDbRef;
    blockHashes: openArray[Hash256];
      ): seq[Hash256]
      {.gcsafe, raises: [RlpError,ValueError].} =
  for blockHash in blockHashes:
    result &= db.getBlockBody(blockHash).uncles.mapIt(it.rlpHash)

proc getUncleHashes*(
    db: CoreDbRef;
    header: BlockHeader;
      ): seq[Hash256]
      {.gcsafe, raises: [RlpError].} =
  if header.ommersHash != EMPTY_UNCLE_HASH:
    let
      key = genericHashKey(header.ommersHash)
      encodedUncles = db.newKvt().get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn logTxt "getUncleHashes()",
            ommersHash=header.ommersHash, action="get()", `error`=($$error)
        return @[]
    return rlp.decode(encodedUncles, seq[BlockHeader]).mapIt(it.rlpHash)

proc getTransactionKey*(
    db: CoreDbRef;
    transactionHash: Hash256;
      ): tuple[blockNumber: BlockNumber, index: int]
      {.gcsafe, raises: [RlpError].} =
  let
    txKey = transactionHashToBlockKey(transactionHash)
    tx = db.newKvt().get(txKey.toOpenArray).valueOr:
      if error.error == KvtNotFound:
        warn logTxt "getTransactionKey()",
          transactionHash, action="get()", `error`=($$error)
      return (0.toBlockNumber, -1)
  let key = rlp.decode(tx, TransactionKey)
  (key.blockNumber, key.index)

proc headerExists*(db: CoreDbRef; blockHash: Hash256): bool =
  ## Returns True if the header with the given block hash is in our DB.
  db.newKvt().hasKey(genericHashKey(blockHash).toOpenArray).valueOr:
    warn logTxt "headerExists()", blockHash, action="get()", `error`=($$error)
    return false

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

  let canonicalHeadHash = canonicalHeadHashKey()
  db.newKvt.put(canonicalHeadHash.toOpenArray, rlp.encode(blockHash)).isOkOr:
    warn logTxt "setHead()", canonicalHeadHash, action="put()", error=($$error)
  return true

proc setHead*(
    db: CoreDbRef;
    header: BlockHeader;
    writeHeader = false;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  var headerHash = rlpHash(header)
  let kvt = db.newKvt()
  if writeHeader:
    kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header)).isOkOr:
      warn logTxt "setHead()", headerHash, action="put()", error=($$error)
      return false
  if not db.markCanonicalChain(header, headerHash):
    return false
  let canonicalHeadHash = canonicalHeadHashKey()
  kvt.put(canonicalHeadHash.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn logTxt "setHead()", canonicalHeadHash, action="put()", error=($$error)
    return false
  true

proc persistReceipts*(
    db: CoreDbRef;
    receipts: openArray[Receipt];
      ) =
  const info = "persistReceipts()"
  if receipts.len == 0:
    return

  let mpt = db.ctx.getMpt(CtReceipts)
  for idx, rec in receipts:
    mpt.merge(rlp.encode(idx), rlp.encode(rec)).isOkOr:
      warn logTxt info, idx, action="merge()", error=($$error)

proc getReceipts*(
    db: CoreDbRef;
    receiptRoot: Hash256;
      ): seq[Receipt]
      {.gcsafe, raises: [RlpError].} =
  var receipts = newSeq[Receipt]()
  for r in db.getReceipts(receiptRoot):
    receipts.add(r)
  return receipts

proc persistScore*(
    db: CoreDbRef;
    blockHash: Hash256;
    score: UInt256
      ): bool =
  let
    kvt = db.newKvt()
    scoreKey = blockHashToScoreKey(blockHash)
  kvt.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    warn logTxt "persistHeader()",
      scoreKey, action="put()", `error`=($$error)
    return
  true

proc persistHeader*(
    db: CoreDbRef;
    blockHash: Hash256;
    header: BlockHeader;
    startOfHistory = GENESIS_PARENT_HASH;
      ): bool =
  let
    kvt = db.newKvt()
    isStartOfHistory = header.parentHash == startOfHistory

  if not isStartOfHistory and not db.headerExists(header.parentHash):
    warn logTxt "persistHeaderWithoutSetHead()",
      blockHash, action="headerExists(parent)"
    return false

  kvt.put(genericHashKey(blockHash).toOpenArray, rlp.encode(header)).isOkOr:
    warn logTxt "persistHeaderWithoutSetHead()",
      blockHash, action="put()", `error`=($$error)
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

  db.addBlockNumberToHashLookup(header.blockNumber, blockHash)
  true

proc persistHeader*(
    db: CoreDbRef;
    header: BlockHeader;
    forceCanonical: bool;
    startOfHistory = GENESIS_PARENT_HASH;
      ): bool =
  let
    blockHash = header.blockHash

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

proc persistUncles*(db: CoreDbRef, uncles: openArray[BlockHeader]): Hash256 =
  ## Persists the list of uncles to the database.
  ## Returns the uncles hash.
  let enc = rlp.encode(uncles)
  result = keccakHash(enc)
  db.newKvt.put(genericHashKey(result).toOpenArray, enc).isOkOr:
    warn logTxt "persistUncles()",
      unclesHash=result, action="put()", `error`=($$error)
    return EMPTY_ROOT_HASH


proc safeHeaderHash*(db: CoreDbRef): Hash256 =
  db.getHash(safeHashKey()).valueOr(Hash256())

proc safeHeaderHash*(db: CoreDbRef, headerHash: Hash256) =
  let safeHashKey = safeHashKey()
  db.newKvt.put(safeHashKey.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn logTxt "safeHeaderHash()",
      safeHashKey, action="put()", `error`=($$error)
    return

proc finalizedHeaderHash*(
    db: CoreDbRef;
      ): Hash256 =
  db.getHash(finalizedHashKey()).valueOr(Hash256())

proc finalizedHeaderHash*(db: CoreDbRef, headerHash: Hash256) =
  let finalizedHashKey = finalizedHashKey()
  db.newKvt.put(finalizedHashKey.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn logTxt "finalizedHeaderHash()",
      finalizedHashKey, action="put()", `error`=($$error)
    return

proc safeHeader*(
    db: CoreDbRef;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  db.getBlockHeader(db.safeHeaderHash)

proc finalizedHeader*(
    db: CoreDbRef;
      ): BlockHeader
      {.gcsafe, raises: [BlockNotFound].} =
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
