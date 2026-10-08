# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/strutils,
  stint,
  results,
  chronicles,
  web3/[eth_api_types, eth_api],
  json_rpc/[rpcserver, rpcclient],
  eth/common/eth_types_rlp,
  eth/rlp,
  eth/trie/[ordered_trie, trie_defs],
  ../../execution_chain/beacon/web3_eth_conv,
  ../../execution_chain/constants,
  ./types,
  ./header_store,
  ./accounts,
  ./transactions

logScope:
  topics = "vp_engine"

const HISTORY_SERVE_WINDOW = 8191'u64

func convHeader*(blk: eth_api_types.BlockObject): Header =
  let nonce = blk.nonce.valueOr:
    default(Bytes8)

  return Header(
    parentHash: blk.parentHash,
    ommersHash: blk.sha3Uncles,
    coinbase: blk.miner,
    stateRoot: blk.stateRoot,
    transactionsRoot: blk.transactionsRoot,
    receiptsRoot: blk.receiptsRoot,
    logsBloom: blk.logsBloom,
    difficulty: blk.difficulty,
    number: base.BlockNumber(distinctBase(blk.number)),
    gasLimit: GasInt(blk.gasLimit.uint64),
    gasUsed: GasInt(blk.gasUsed.uint64),
    timestamp: ethTime(blk.timestamp),
    extraData: seq[byte](blk.extraData),
    mixHash: Bytes32(distinctBase(blk.mixHash)),
    nonce: nonce,
    baseFeePerGas: blk.baseFeePerGas,
    withdrawalsRoot: blk.withdrawalsRoot,
    blobGasUsed: blk.blobGasUsed.u64,
    excessBlobGas: blk.excessBlobGas.u64,
    parentBeaconBlockRoot: blk.parentBeaconBlockRoot,
    requestsHash: blk.requestsHash,
  )

func isEIP2935Active(engine: RpcVerificationEngine, header: Header): bool =
  engine.eip2935ForkTime.isSome() and header.timestamp >= engine.eip2935ForkTime.get()

func inEIP2935Range(
    engine: RpcVerificationEngine, anchor: Header, target: Header
): bool =
  if not (engine.isEIP2935Active(anchor) and engine.isEIP2935Active(target)):
    return false

  if target.number >= anchor.number:
    return false

  # because div floors we add one to ceil it to the next integer
  let jumps = (anchor.number - target.number - 1) div HISTORY_SERVE_WINDOW + 1

  jumps <= engine.maxWindowJumps

proc getEIP2935Hash(
    engine: RpcVerificationEngine, anchor: Header, number: base.BlockNumber
): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
  let slot = (number mod HISTORY_SERVE_WINDOW).u256

  let storedValue = (
    await engine.getStorageAt(
      HISTORY_STORAGE_ADDRESS, slot, anchor.number, anchor.stateRoot
    )
  ).valueOr:
    error "Failed to fetch EIP-2935 storage proof",
      anchorNumber = anchor.number, number, slot, err = error.errMsg
    return err(error)

  # storage value is zero only when the fork activated less than 8191 blocks before
  if storedValue.isZero():
    error "EIP-2935 storage slot is empty, fork activated too recently",
      anchorNumber = anchor.number, number, slot
    return err(
      (
        UnavailableDataError,
        "the EIP-2935 history slot for the requested block is empty", UNTAGGED,
      )
    )

  ok(storedValue.toBytesBE().to(Hash32))

proc getTrustedHeader(
    engine: RpcVerificationEngine, hash: Hash32, trust: HeaderTrust
): Future[EngineResult[Header]] {.async: (raises: [CancelledError]).} =
  let cached = engine.headerStore.get(hash, None)
  if cached.isSome():
    engine.headerStore.put(cached.get(), hash, trust)
    return ok(cached.get())

  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByHash))
    blk = ?((await backend.eth_getBlockByHash(hash, false)).tagBackend(backendIdx))
    header = convHeader(blk)

  if header.computeBlockHash != hash:
    return err(
      (
        VerificationError, "the downloaded anchor header doesn't match the anchor hash",
        backendIdx,
      )
    )

  engine.headerStore.put(header, hash, trust)

  ok(header)

func verifyBlock(blk: BlockObject, fullTransactions: bool): EngineResult[void] =
  # verify transactions
  if fullTransactions:
    ?verifyTransactions(blk.transactionsRoot, blk.transactions)

  if blk.withdrawals.isSome() and blk.withdrawalsRoot.isSome():
    if blk.withdrawalsRoot.get() != orderedTrieRoot(blk.withdrawals.get()):
      # untagged(-1) so the relevant backend can be tagged
      return err(
        (
          VerificationError,
          "Withdrawals within the block do not yield the same withdrawals root",
          UNTAGGED,
        )
      )

  ok()

proc getTrustedBlock(
    engine: RpcVerificationEngine,
    hash: Hash32,
    trust: HeaderTrust,
    fullTransactions: bool,
): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByHash))
    blk = ?(
      (await backend.eth_getBlockByHash(hash, fullTransactions)).tagBackend(backendIdx)
    )
    header = convHeader(blk)

  if header.computeBlockHash != hash:
    return err(
      (
        VerificationError, "the downloaded anchor block doesn't match the anchor hash",
        backendIdx,
      )
    )

  ?(verifyBlock(blk, fullTransactions).tagBackend(backendIdx))

  engine.headerStore.put(header, hash, trust)

  ok(blk)

proc verifyEIP2935Membership(
    engine: RpcVerificationEngine,
    anchor: Header,
    trust: HeaderTrust,
    target: Header,
    targetHash: Hash32,
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  if not engine.inEIP2935Range(anchor, target):
    # untagged(-1) because this doesn't link to any backend
    return err(
      (
        UnavailableDataError,
        "EIP-2935 cannot reach the requested block from the verified anchor", UNTAGGED,
      )
    )

  let targetNum = target.number

  var curAnchor = anchor
  while curAnchor.number - targetNum > HISTORY_SERVE_WINDOW:
    let newAnchorNum =
      ((curAnchor.number - 1) div HISTORY_SERVE_WINDOW) * HISTORY_SERVE_WINDOW

    # get cached header by number because hash will require getProof
    let cachedJump = engine.headerStore.get(newAnchorNum, Finalized)
    if cachedJump.isSome():
      curAnchor = cachedJump.get()
      continue

    let storedHash = (await engine.getEIP2935Hash(curAnchor, newAnchorNum)).valueOr:
      # we already checked if the target is in range of EIP2935 despite that the hash
      # is unavailable so it translated to a verification error
      if error.errType == UnavailableDataError:
        return err((VerificationError, error.errMsg, error.backendIdx))
      return err(error)

    let header = (await engine.getTrustedHeader(storedHash, trust)).valueOr:
      error "Couldn't fetch the EIP-2935 window jump header",
        curAnchorNumber = curAnchor.number, newAnchorNum, storedHash, err = error.errMsg
      return err(error)

    if header.number != newAnchorNum:
      error "EIP-2935 window jump header has an unexpected block number",
        curAnchorNumber = curAnchor.number,
        newAnchorNum,
        storedHash,
        downloadedNumber = header.number
      return err(
        (
          VerificationError,
          "the EIP-2935 stored hash resolves to a block of a different number", UNTAGGED,
        )
      )

    curAnchor = header

  let storedHash = (await engine.getEIP2935Hash(curAnchor, targetNum)).valueOr:
    # we already checked if the target is in range of EIP2935 despite that the hash
    # is unavailable so it translated to a verification error
    if error.errType == UnavailableDataError:
      return err((VerificationError, error.errMsg, error.backendIdx))
    return err(error)

  if storedHash == targetHash:
    return ok()

  error "EIP-2935 verification failed, block is not part of the canonical chain",
    curAnchorNumber = curAnchor.number, targetNum, targetHash, storedHash
  err(
    (
      VerificationError, "the requested block is not part of the canonical chain",
      UNTAGGED,
    )
  )

func snapshotAnchors*(engine: RpcVerificationEngine): EngineResult[AnchorHashes] =
  if engine.headerStore.getHash(Optimistic).isNone() and
      engine.headerStore.getHash(Safe).isNone():
    return err(
      (
        UnavailableDataError, "no verified anchor is available yet. Still syncing?",
        UNTAGGED,
      )
    )

  ok(
    AnchorHashes(
      latest: engine.headerStore.getHash(Optimistic),
      safe: engine.headerStore.getHash(Safe),
      finalized: engine.headerStore.getHash(Finalized),
      earliest: engine.headerStore.getEarliestHash(),
    )
  )

proc walkBlocks(
    engine: RpcVerificationEngine,
    sourceNum: base.BlockNumber,
    targetNum: base.BlockNumber,
    sourceHash: Hash32,
    trust: HeaderTrust,
): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
  debug "Starting block walk", sourceNum, targetNum

  if targetNum >= sourceNum:
    return err(
      (
        FrontendError, "the block walk target is not older than the walk source",
        UNTAGGED,
      )
    )

  let numBlocks = sourceNum - targetNum
  if numBlocks > engine.maxBlockWalk:
    return err(
      (
        FrontendError,
        "Cannot query more than " & $engine.maxBlockWalk &
          " to verify the chain for the requested block",
        UNTAGGED,
      )
    )

  var
    nextHash = sourceHash # sourceHash is already the parent hash
    nextNum = sourceNum - 1
    downloadedHeaders: Table[Hash32, Header]
    futs: seq[Future[EngineResult[BlockObject]]]

  while nextNum > targetNum:
    let cached = engine.headerStore.get(nextHash, None)
    if cached.isSome():
      engine.headerStore.put(cached.get(), nextHash, trust)
      nextHash = cached.get().parentHash
      nextNum -= 1
      continue

    futs = @[]
    downloadedHeaders.clear()

    # select one backend for batch requests
    let (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByNumber))

    var fetchNum = nextNum
    while fetchNum > targetNum and
        uint64(futs.len) < max(1'u64, engine.parallelBlockDownloads):
      # cached blocks don't consume the download budget
      if engine.headerStore.getHash(fetchNum, Finalized).isNone():
        let tag = BlockTag(kind: bidNumber, number: Quantity(fetchNum))
        futs.add(backend.eth_getBlockByNumber(tag, false))
      fetchNum -= 1

    await allFutures(futs)

    for futBlk in futs:
      if not futBlk.completed():
        return
          err((BackendFetchError, "block download failed or cancelled", backendIdx))
      let
        blk = ?(futBlk.value().tagBackend(backendIdx))
        h = convHeader(blk)
      downloadedHeaders[blk.hash] = h

    while nextNum > fetchNum:
      let cachedLink = engine.headerStore.get(nextHash, None)
      let unverifiedHeader =
        if cachedLink.isSome():
          cachedLink.get()
        else:
          try:
            downloadedHeaders[nextHash]
          except KeyError:
            return err(
              (
                UnavailableDataError, "Cannot find downloaded block of the block walk",
                backendIdx,
              )
            )

      if unverifiedHeader.computeBlockHash != nextHash or
          unverifiedHeader.number != nextNum:
        return err(
          (
            VerificationError,
            "Encountered an invalid block header while walking the chain", backendIdx,
          )
        )

      engine.headerStore.put(unverifiedHeader, nextHash, trust)

      nextHash = unverifiedHeader.parentHash
      nextNum -= 1

  ok(nextHash)

proc verifyHeader(
    engine: RpcVerificationEngine,
    anchor: Header,
    trust: HeaderTrust,
    header: Header,
    hash: Hash32,
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  # verify calculated hash with the requested hash
  if header.computeBlockHash != hash:
    # untagged(-1) so the relevant backend can be tagged
    return err(
      (
        VerificationError,
        "hashed block header doesn't match with blk.hash(downloaded)", UNTAGGED,
      )
    )

  # if the header is available in the store just use that (already verified)
  if engine.headerStore.get(hash, trust).isSome():
    return ok()

  if header.number == anchor.number:
    if hash != anchor.computeBlockHash:
      return err(
        (
          VerificationError, "the requested block is not part of the canonical chain",
          UNTAGGED,
        )
      )

    engine.headerStore.put(header, hash, trust)
    return ok()

  # EIP-2935 jumps read proofs at the anchor's state root, only an archive
  # backend can serve those. without one we walk the chain instead
  if engine.state.archive:
    ?(await engine.verifyEIP2935Membership(anchor, trust, header, hash))
  else:
    let walkedHash =
      ?(await engine.walkBlocks(anchor.number, header.number, anchor.parentHash, trust))

    if walkedHash != hash:
      return err(
        (
          VerificationError, "the requested block is not part of the canonical chain",
          UNTAGGED,
        )
      )

  engine.headerStore.put(header, hash, trust)

  ok()

proc getBlockHash*(
    engine: RpcVerificationEngine, anchor: Header, number: base.BlockNumber
): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
  if number >= anchor.number:
    return err(
      (
        InvalidDataError, "block hash requested for a block that is not in the past",
        UNTAGGED,
      )
    )

  let cached = engine.headerStore.getHash(number, Finalized)
  if cached.isSome():
    return ok(cached.get())

  if engine.isEIP2935Active(anchor) and anchor.number - number <= HISTORY_SERVE_WINDOW:
    return await engine.getEIP2935Hash(anchor, number)

  err(
    (
      UnavailableDataError,
      "EIP-2935 cannot reach the requested block from the verified anchor", UNTAGGED,
    )
  )

proc getBlock*(
    engine: RpcVerificationEngine,
    anchor: Header,
    trust: HeaderTrust,
    blockHash: Hash32,
    fullTransactions: bool,
): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
  # get the target block
  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByHash))
    blk = ?(
      (await backend.eth_getBlockByHash(blockHash, fullTransactions)).tagBackend(
        backendIdx
      )
    )

  # verify requested hash with the downloaded hash
  if blockHash != blk.hash:
    return err(
      (
        VerificationError,
        "the downloaded block hash doesn't match with the requested hash", backendIdx,
      )
    )

  # verify the block
  ?(
    (await engine.verifyHeader(anchor, trust, convHeader(blk), blk.hash)).tagBackend(
      backendIdx
    )
  )

  ?(verifyBlock(blk, fullTransactions).tagBackend(backendIdx))

  ok(blk)

proc getBlock*(
    engine: RpcVerificationEngine,
    anchor: Header,
    trust: HeaderTrust,
    blockTag: BlockTag,
    fullTransactions: bool,
): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
  if blockTag.kind != bidNumber:
    # untagged(-1) so the relevant backend can be tagged
    return
      err((InvalidDataError, "a block number is required to fetch by number", UNTAGGED))

  # get the target block
  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByNumber))
    blk = ?(
      (await backend.eth_getBlockByNumber(blockTag, fullTransactions)).tagBackend(
        backendIdx
      )
    )

  if blockTag.number != blk.number:
    return err(
      (
        VerificationError,
        "the downloaded block number doesn't match with the requested block number",
        backendIdx,
      )
    )

  # verify the block
  ?(
    (await engine.verifyHeader(anchor, trust, convHeader(blk), blk.hash)).tagBackend(
      backendIdx
    )
  )

  ?(verifyBlock(blk, fullTransactions).tagBackend(backendIdx))

  ok(blk)

proc getHeader*(
    engine: RpcVerificationEngine, anchor: Header, trust: HeaderTrust, blockHash: Hash32
): Future[EngineResult[Header]] {.async: (raises: [CancelledError]).} =
  let cachedHeader = engine.headerStore.get(blockHash, trust)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockHash = blockHash
  else:
    return ok(cachedHeader.get())

  # get the target block
  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByHash))
    blk = ?((await backend.eth_getBlockByHash(blockHash, false)).tagBackend(backendIdx))

  let header = convHeader(blk)

  if blockHash != blk.hash:
    return err(
      (
        VerificationError,
        "the blk.hash(downloaded) doesn't match with the provided hash", backendIdx,
      )
    )

  ?(
    (await engine.verifyHeader(anchor, trust, header, blockHash)).tagBackend(backendIdx)
  )

  ok(header)

proc getHeader*(
    engine: RpcVerificationEngine,
    anchor: Header,
    trust: HeaderTrust,
    blockTag: BlockTag,
): Future[EngineResult[Header]] {.async: (raises: [CancelledError]).} =
  if blockTag.kind != bidNumber:
    # untagged(-1) so the relevant backend can be tagged
    return
      err((InvalidDataError, "a block number is required to fetch by number", UNTAGGED))

  let
    n = distinctBase(blockTag.number)
    cachedHeader = engine.headerStore.get(base.BlockNumber(n), trust)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockTag = blockTag
  else:
    return ok(cachedHeader.get())

  # get the target block
  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByNumber))
    blk =
      ?((await backend.eth_getBlockByNumber(blockTag, false)).tagBackend(backendIdx))

  let header = convHeader(blk)

  if n != header.number:
    return err(
      (
        VerificationError,
        "the downloaded block number doesn't match with the requested block number",
        backendIdx,
      )
    )

  ?((await engine.verifyHeader(anchor, trust, header, blk.hash)).tagBackend(backendIdx))

  ok(header)

# tags are strict, they resolve to the anchor of the trust level they name.
# numbers and hashes get the best anchor that can verify them
proc getVerified[T](
    engine: RpcVerificationEngine,
    blockTag: BlockTag,
    fullTransactions: bool,
    snapshot: Opt[AnchorHashes],
): Future[EngineResult[T]] {.async: (raises: [CancelledError]).} =
  # a caller that resolves more than one tag per request passes its own snapshot
  # so that every tag resolves against the same anchors
  let anchors =
    if snapshot.isSome():
      snapshot.get()
    else:
      ?engine.snapshotAnchors()

  case blockTag.kind
  of bidAlias:
    var
      anchorHash: Opt[Hash32]
      trust: HeaderTrust

    case blockTag.alias.toLowerAscii()
    of "latest":
      anchorHash = anchors.latest
      trust = Optimistic
    of "safe":
      anchorHash = anchors.safe
      trust = Safe
    of "finalized":
      anchorHash = anchors.finalized
      trust = Finalized
    of "earliest":
      anchorHash = anchors.earliest
      trust = Finalized
    else:
      # untagged(-1) so the relevant backend can be tagged
      return err((InvalidDataError, "No support for block tag " & $blockTag, UNTAGGED))

    let hash = anchorHash.valueOr:
      return
        err((UnavailableDataError, $blockTag & " block is not available yet", UNTAGGED))

    # the anchor hash is the answer, trust is the label it is stored with
    when T is Header:
      return await engine.getTrustedHeader(hash, trust)
    else:
      return await engine.getTrustedBlock(hash, trust, fullTransactions)
  of bidNumber, bidHash:
    # without requireCanonical the hash pins the block, so it anchors itself
    if blockTag.kind == bidHash and not blockTag.requireCanonical:
      when T is Header:
        return await engine.getTrustedHeader(blockTag.hash, None)
      else:
        return await engine.getTrustedBlock(blockTag.hash, None, fullTransactions)

    let number =
      if blockTag.kind == bidNumber:
        base.BlockNumber(distinctBase(blockTag.number))
      else:
        (?(await engine.getTrustedHeader(blockTag.hash, None))).number

    var
      anchor: Header
      trust = Optimistic

    block pickAnchor:
      if anchors.finalized.isSome():
        let finalized =
          ?(await engine.getTrustedHeader(anchors.finalized.get(), Finalized))
        if number <= finalized.number:
          anchor = finalized
          trust = Finalized
          break pickAnchor

      if anchors.safe.isSome():
        let safe = ?(await engine.getTrustedHeader(anchors.safe.get(), Safe))
        if number <= safe.number:
          anchor = safe
          trust = Safe
          break pickAnchor

      let latestHash = anchors.latest.valueOr:
        return err(
          (
            UnavailableDataError, "no verified anchor covers the requested block",
            UNTAGGED,
          )
        )

      anchor = ?(await engine.getTrustedHeader(latestHash, Optimistic))
      if number > anchor.number:
        return err(
          (
            UnavailableDataError,
            "the requested block is newer than the latest verified block", UNTAGGED,
          )
        )

    if blockTag.kind == bidNumber and number == anchor.number:
      when T is Header:
        return await engine.getTrustedHeader(anchor.computeBlockHash, trust)
      else:
        return
          await engine.getTrustedBlock(anchor.computeBlockHash, trust, fullTransactions)

    if blockTag.kind == bidHash:
      when T is Header:
        return await engine.getHeader(anchor, trust, blockTag.hash)
      else:
        return await engine.getBlock(anchor, trust, blockTag.hash, fullTransactions)

    when T is Header:
      return await engine.getHeader(anchor, trust, blockTag)
    else:
      return await engine.getBlock(anchor, trust, blockTag, fullTransactions)

proc getVerifiedHeader*(
    engine: RpcVerificationEngine, blockTag: BlockTag, snapshot = Opt.none(AnchorHashes)
): Future[EngineResult[Header]] {.async: (raises: [CancelledError]).} =
  await getVerified[Header](engine, blockTag, false, snapshot)

proc getVerifiedBlock*(
    engine: RpcVerificationEngine,
    blockTag: BlockTag,
    fullTransactions: bool,
    snapshot = Opt.none(AnchorHashes),
): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
  await getVerified[BlockObject](engine, blockTag, fullTransactions, snapshot)
