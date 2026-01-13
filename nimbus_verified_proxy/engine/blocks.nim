# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/strutils,
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
        return err(
          (
            UnavailableDataError,
            "Couldn't get the latest block number from header store",
          )
        )
      ok(BlockTag(kind: bidNumber, number: Quantity(hLatest.number)))
    of "finalized":
      let hFinalized = engine.headerStore.finalized.valueOr:
        return err(
          (
            UnavailableDataError,
            "Couldn't get the finalized block number from header store",
          )
        )
      ok(BlockTag(kind: bidNumber, number: Quantity(hFinalized.number)))
    of "earliest":
      let hEarliest = engine.headerStore.earliest.valueOr:
        return err(
          (
            UnavailableDataError,
            "Couldn't get the earliest block number from header store",
          )
        )
      ok(BlockTag(kind: bidNumber, number: Quantity(hEarliest.number)))
    else:
      err((InvalidDataError, "No support for block tag " & $blockTag))
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
        VerificationError,
        "Cannot query more than " & $engine.maxBlockWalk &
          " to verify the chain for the requested block",
      )
    )

  var
    nextHash = sourceHash # sourceHash is already the parent hash
    nextNum = sourceNum - 1
    downloadedHeaders: Table[base.BlockNumber, Header]

  while nextNum > targetNum:
    let numDownloads =
      if ((nextNum - engine.parallelBlockDownloads + 1) > targetNum):
        engine.parallelBlockDownloads
      else:
        nextNum - targetNum

    for i in nextNum - numDownloads + 1 .. nextNum:
      let header =
        if engine.headerStore.contains(i):
          engine.headerStore.get(i).get()
        else:
          let
            blk =
              ?(
                await engine.backend.eth_getBlockByNumber(
                  BlockTag(kind: bidNumber, number: Quantity(i)), false
                )
              )

            h = convHeader(blk)

          h

      downloadedHeaders[i] = header

    for j in 0 ..< numDownloads:
      let unverifiedHeader =
        try:
          downloadedHeaders[nextNum - j]
        except KeyError as e:
          return err(
            (UnavailableDataError, "Cannot find downloaded block of the block walk")
          )

      if unverifiedHeader.computeBlockHash != nextHash:
        return err(
          (
            VerificationError,
            "Encountered an invalid block header while walking the chain",
          )
        )

      if unverifiedHeader.parentHash == targetHash:
        return ok()

      nextHash = unverifiedHeader.parentHash

    downloadedHeaders.clear()

    nextNum = nextNum - numDownloads # because we walk along the history(past)

  err((VerificationError, "the requested block is not part of the canonical chain"))

proc verifyHeader(
    engine: RpcVerificationEngine, header: Header, hash: Hash32
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  # verify calculated hash with the requested hash
  if header.computeBlockHash != hash:
    return err(
      (VerificationError, "hashed block header doesn't match with blk.hash(downloaded)")
    )

  # if the header is available in the store just use that (already verified)
  if engine.headerStore.contains(hash):
    return ok()
  # walk blocks backwards(time) from source to target
  else:
    let
      earliest = engine.headerStore.earliest.valueOr:
        return err(
          (UnavailableDataError, "earliest block is not available yet. Still syncing?")
        )
      finalized = engine.headerStore.finalized.valueOr:
        return err(
          (UnavailableDataError, "finalized block is not available yet. Still syncing?")
        )
      latest = engine.headerStore.latest.valueOr:
        return err(
          (UnavailableDataError, "latest block is not available yet. Still syncing?")
        )

    # header is older than earliest and earliest is finalized
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
    # is within the boundaries of header store but not found
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
      return err(
        (
          VerificationError,
          "Withdrawals within the block do not yield the same withdrawals root",
        )
      )
  else:
    if blk.withdrawals.isSome():
      return
        err((VerificationError, "Block contains withdrawals but no withdrawalsRoot"))

  ok()

proc getBlock*(
    engine: RpcVerificationEngine, blockHash: Hash32, fullTransactions: bool
): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
  # get the target block
  let blk = ?(await engine.backend.eth_getBlockByHash(blockHash, fullTransactions))

  # verify requested hash with the downloaded hash
  if blockHash != blk.hash:
    return err(
      (
        VerificationError,
        "the downloaded block hash doesn't match with the requested hash",
      )
    )

  # verify the block
  ?(await engine.verifyBlock(blk, fullTransactions))

  ok(blk)

proc getBlock*(
    engine: RpcVerificationEngine, blockTag: BlockTag, fullTransactions: bool
): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
  let numberTag = ?engine.resolveBlockTag(blockTag)

  # get the target block
  let blk = ?(await engine.backend.eth_getBlockByNumber(numberTag, fullTransactions))

  if numberTag.number != blk.number:
    return err(
      (
        VerificationError,
        "the downloaded block number doesn't match with the requested block number",
      )
    )

  # verify the block
  ?(await engine.verifyBlock(blk, fullTransactions))

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
  let blk = ?(await engine.backend.eth_getBlockByHash(blockHash, false))

  let header = convHeader(blk)

  if blockHash != blk.hash:
    return err(
      (
        VerificationError,
        "the blk.hash(downloaded) doesn't match with the provided hash",
      )
    )

  ?(await engine.verifyHeader(header, blockHash))

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
  let blk = ?(await engine.backend.eth_getBlockByNumber(numberTag, false))

  let header = convHeader(blk)

  if n != header.number:
    return err(
      (
        VerificationError,
        "the downloaded block number doesn't match with the requested block number",
      )
    )

  ?(await engine.verifyHeader(header, blk.hash))

  ok(header)
