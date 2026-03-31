# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[strutils, sequtils],
  results,
  chronicles,
  web3/[eth_api_types, eth_api],
  json_rpc/[rpcserver, rpcclient],
  eth/common/eth_types_rlp,
  eth/rlp,
  eth/trie/[ordered_trie, trie_defs],
  ../../execution_chain/beacon/web3_eth_conv,
  ./types,
  ./header_store,
  ./transactions

proc resolveBlockTag*(
    engine: RpcVerificationEngine, blockTag: BlockTag
): EngineResult[BlockTag] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii()
    case tag
    of "latest":
      let hLatest = engine.headerStore.latest.valueOr:
        # untagged(-1) so the relevant backend can be tagged
        return err(
          (
            UnavailableDataError,
            "Couldn't get the latest block number from header store", UNTAGGED,
          )
        )
      ok(BlockTag(kind: bidNumber, number: Quantity(hLatest.number)))
    of "finalized":
      let hFinalized = engine.headerStore.finalized.valueOr:
        # untagged(-1) so the relevant backend can be tagged
        return err(
          (
            UnavailableDataError,
            "Couldn't get the finalized block number from header store", UNTAGGED,
          )
        )
      ok(BlockTag(kind: bidNumber, number: Quantity(hFinalized.number)))
    of "earliest":
      let hEarliest = engine.headerStore.earliest.valueOr:
        # untagged(-1) so the relevant backend can be tagged
        return err(
          (
            UnavailableDataError,
            "Couldn't get the earliest block number from header store", UNTAGGED,
          )
        )
      ok(BlockTag(kind: bidNumber, number: Quantity(hEarliest.number)))
    else:
      # untagged(-1) so the relevant backend can be tagged
      err((InvalidDataError, "No support for block tag " & $blockTag, UNTAGGED))
  else:
    ok(blockTag)

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

proc walkBlocks(
    engine: RpcVerificationEngine,
    sourceNum: base.BlockNumber,
    targetNum: base.BlockNumber,
    sourceHash: Hash32,
    targetHash: Hash32,
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  info "Starting block walk to verify requested block", blockHash = targetHash

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
    futs = @[]
    downloadedHeaders.clear()

    # select one backend for batch requests
    let (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByNumber))

    while nextNum > targetNum and uint64(futs.len) < engine.parallelBlockDownloads:
      if not engine.headerStore.contains(nextNum):
        let tag = BlockTag(kind: bidNumber, number: Quantity(nextNum))
        futs.add(backend.eth_getBlockByNumber(tag, false))

      nextNum -= 1

    await allFutures(futs)

    for futBlk in futs:
      if not futBlk.completed():
        return
          err((BackendFetchError, "block download failed or cancelled", backendIdx))
      let
        blk = ?(futBlk.value().tagBackend(backendIdx))
        h = convHeader(blk)
      downloadedHeaders[blk.hash] = h

    for j in 0 ..< futs.len:
      let unverifiedHeader =
        if engine.headerStore.contains(nextHash):
          engine.headerStore.get(nextHash).get()
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

      if unverifiedHeader.computeBlockHash != nextHash:
        return err(
          (
            VerificationError,
            "Encountered an invalid block header while walking the chain", backendIdx,
          )
        )

      if unverifiedHeader.parentHash == targetHash:
        return ok()

      nextHash = unverifiedHeader.parentHash

  # untagged(-1) so the relevant backend can be tagged. Since this is not the fault of the
  # backends that were responsible for the block walk
  err(
    (
      VerificationError, "the requested block is not part of the canonical chain",
      UNTAGGED,
    )
  )

proc verifyHeader(
    engine: RpcVerificationEngine, header: Header, hash: Hash32
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
  if engine.headerStore.contains(hash):
    return ok()
  # walk blocks backwards(time) from source to target
  else:
    let
      earliest = engine.headerStore.earliest.valueOr:
        # untagged(-1) because this doesn't link to any backend
        return err(
          (
            UnavailableDataError, "earliest block is not available yet. Still syncing?",
            UNTAGGED,
          )
        )
      finalized = engine.headerStore.finalized.valueOr:
        # untagged(-1) because this doesn't link to any backend
        return err(
          (
            UnavailableDataError,
            "finalized block is not available yet. Still syncing?", UNTAGGED,
          )
        )
      latest = engine.headerStore.latest.valueOr:
        # untagged(-1) because this doesn't link to any backend
        return err(
          (
            UnavailableDataError, "latest block is not available yet. Still syncing?",
            UNTAGGED,
          )
        )

    # header is older than earliest
    if header.number < earliest.number:
      # earliest is finalized
      if earliest.number < finalized.number:
        ?await engine.walkBlocks(
          earliest.number, header.number, earliest.parentHash, hash
        )
      # earliest is not finalized (headerstore is smaller than 2 epochs or chain hasn't finalized for long)
      else:
        ?await engine.walkBlocks(
          finalized.number, header.number, finalized.parentHash, hash
        )
    # is within the boundaries of header store but not found in cache
    else:
      if header.number < finalized.number:
        ?await engine.walkBlocks(
          finalized.number, header.number, finalized.parentHash, hash
        )
      else:
        # optimistic walk
        ?await engine.walkBlocks(latest.number, header.number, latest.parentHash, hash)

  ok()

proc verifyBlock(
    engine: RpcVerificationEngine, blk: BlockObject, fullTransactions: bool
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  let header = convHeader(blk)

  ?(await engine.verifyHeader(header, blk.hash))

  # verify transactions
  if fullTransactions:
    ?verifyTransactions(header.transactionsRoot, blk.transactions)

  # verify withdrawals
  if blk.withdrawalsRoot.isSome():
    if blk.withdrawalsRoot.get() != orderedTrieRoot(blk.withdrawals.get(@[])):
      # untagged(-1) so the relevant backend can be tagged
      return err(
        (
          VerificationError,
          "Withdrawals within the block do not yield the same withdrawals root",
          UNTAGGED,
        )
      )
  else:
    if blk.withdrawals.isSome():
      # untagged(-1) so the relevant backend can be tagged
      return err(
        (
          VerificationError, "Block contains withdrawals but no withdrawalsRoot",
          UNTAGGED,
        )
      )

  ok()

proc getBlock*(
    engine: RpcVerificationEngine, blockHash: Hash32, fullTransactions: bool
): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
  # get the target block
  let
<<<<<<< HEAD
    (backend, backendIdx) = ?(engine.backendFor(GetBlockByHash))
    blk = ?(
      (await backend.eth_getBlockByHash(blockHash, fullTransactions)).tagBackend(
        backendIdx
=======
    (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByHash))
    blk =
      ?(
        (await backend.eth_getBlockByHash(blockHash, fullTransactions)).tagBackend(
          backendIdx
        )
>>>>>>> 796885755 (refactor and extend scoring for lc)
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
  ?((await engine.verifyBlock(blk, fullTransactions)).tagBackend(backendIdx))

  ok(blk)

proc getBlock*(
    engine: RpcVerificationEngine, blockTag: BlockTag, fullTransactions: bool
): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
  let numberTag = ?engine.resolveBlockTag(blockTag)

  # get the target block
  let
<<<<<<< HEAD
    (backend, backendIdx) = ?(engine.backendFor(GetBlockByNumber))
    blk = ?(
      (await backend.eth_getBlockByNumber(numberTag, fullTransactions)).tagBackend(
        backendIdx
=======
    (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByNumber))
    blk =
      ?(
        (await backend.eth_getBlockByNumber(numberTag, fullTransactions)).tagBackend(
          backendIdx
        )
>>>>>>> 796885755 (refactor and extend scoring for lc)
      )
    )

  if numberTag.number != blk.number:
    return err(
      (
        VerificationError,
        "the downloaded block number doesn't match with the requested block number",
        backendIdx,
      )
    )

  # verify the block
  ?((await engine.verifyBlock(blk, fullTransactions)).tagBackend(backendIdx))

  ok(blk)

proc getHeader*(
    engine: RpcVerificationEngine, blockHash: Hash32
): Future[EngineResult[Header]] {.async: (raises: [CancelledError]).} =
  let cachedHeader = engine.headerStore.get(blockHash)

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

  ?((await engine.verifyHeader(header, blockHash)).tagBackend(backendIdx))

  ok(header)

proc getHeader*(
    engine: RpcVerificationEngine, blockTag: BlockTag
): Future[EngineResult[Header]] {.async: (raises: [CancelledError]).} =
  let
    numberTag = ?engine.resolveBlockTag(blockTag)
    n = distinctBase(numberTag.number)
    cachedHeader = engine.headerStore.get(n)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockTag = blockTag
  else:
    return ok(cachedHeader.get())

  # get the target block
  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetBlockByNumber))
    blk =
      ?((await backend.eth_getBlockByNumber(numberTag, false)).tagBackend(backendIdx))

  let header = convHeader(blk)

  if n != header.number:
    return err(
      (
        VerificationError,
        "the downloaded block number doesn't match with the requested block number",
        backendIdx,
      )
    )

  ?((await engine.verifyHeader(header, blk.hash)).tagBackend(backendIdx))

  ok(header)
