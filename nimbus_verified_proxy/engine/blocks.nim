# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
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
): Result[BlockTag, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii()
    case tag
    of "latest":
      let hLatest = engine.headerStore.latest.valueOr:
        return err("Couldn't get the latest block number from header store")
      ok(BlockTag(kind: bidNumber, number: Quantity(hLatest.number)))
    of "finalized":
      let hFinalized = engine.headerStore.finalized.valueOr:
        return err("Couldn't get the latest block number from header store")
      ok(BlockTag(kind: bidNumber, number: Quantity(hFinalized.number)))
    of "earliest":
      let hEarliest = engine.headerStore.earliest.valueOr:
        return err("Couldn't get the latest block number from header store")
      ok(BlockTag(kind: bidNumber, number: Quantity(hEarliest.number)))
    else:
      err("No support for block tag " & $blockTag)
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
): Future[Result[void, string]] {.async: (raises: []).} =
  var nextHash = sourceHash
  info "Starting block walk to verify requested block", blockHash = targetHash

  let numBlocks = sourceNum - targetNum
  if numBlocks > engine.maxBlockWalk:
    return err(
      "Cannot query more than " & $engine.maxBlockWalk &
        " to verify the chain for the requested block"
    )

  for i in 0 ..< numBlocks:
    let nextHeader =
      if engine.headerStore.contains(nextHash):
        engine.headerStore.get(nextHash).get()
      else:
        let blk =
          try:
            await engine.backend.eth_getBlockByHash(nextHash, false)
          except CatchableError as e:
            return err(
              "Couldn't get block " & $nextHash & " during the chain traversal: " & e.msg
            )

        trace "getting next block",
          hash = nextHash,
          number = blk.number,
          remaining = distinctBase(blk.number) - targetNum

        let header = convHeader(blk)

        if header.computeBlockHash != nextHash:
          return err("Encountered an invalid block header while walking the chain")

        header

    if nextHeader.parentHash == targetHash:
      return ok()

    nextHash = nextHeader.parentHash

  err("the requested block is not part of the canonical chain")

proc verifyHeader(
    engine: RpcVerificationEngine, header: Header, hash: Hash32
): Future[Result[void, string]] {.async: (raises: []).} =
  # verify calculated hash with the requested hash
  if header.computeBlockHash != hash:
    return err("hashed block header doesn't match with blk.hash(downloaded)")

  if not engine.headerStore.contains(hash):
    let latestHeader = engine.headerStore.latest.valueOr:
      return err("Couldn't get the latest header, syncing in progress")

    # walk blocks backwards(time) from source to target
    ?(
      await engine.walkBlocks(
        latestHeader.number, header.number, latestHeader.parentHash, hash
      )
    )

  ok()

proc verifyBlock(
    engine: RpcVerificationEngine, blk: BlockObject, fullTransactions: bool
): Future[Result[void, string]] {.async: (raises: []).} =
  let header = convHeader(blk)

  ?(await engine.verifyHeader(header, blk.hash))

  # verify transactions
  if fullTransactions:
    ?verifyTransactions(header.transactionsRoot, blk.transactions)

  # verify withdrawals
  if blk.withdrawalsRoot.isSome():
    if blk.withdrawalsRoot.get() != orderedTrieRoot(blk.withdrawals.get(@[])):
      return err("Withdrawals within the block do not yield the same withdrawals root")
  else:
    if blk.withdrawals.isSome():
      return err("Block contains withdrawals but no withdrawalsRoot")

  ok()

proc getBlock*(
    engine: RpcVerificationEngine, blockHash: Hash32, fullTransactions: bool
): Future[Result[BlockObject, string]] {.async: (raises: []).} =
  # get the target block
  let blk =
    try:
      await engine.backend.eth_getBlockByHash(blockHash, fullTransactions)
    except CatchableError as e:
      return err(e.msg)

  # verify requested hash with the downloaded hash
  if blockHash != blk.hash:
    return err("the downloaded block hash doesn't match with the requested hash")

  # verify the block
  ?(await engine.verifyBlock(blk, fullTransactions))

  ok(blk)

proc getBlock*(
    engine: RpcVerificationEngine, blockTag: BlockTag, fullTransactions: bool
): Future[Result[BlockObject, string]] {.async: (raises: []).} =
  let numberTag = engine.resolveBlockTag(blockTag).valueOr:
    return err(error)

  # get the target block
  let blk =
    try:
      await engine.backend.eth_getBlockByNumber(numberTag, fullTransactions)
    except CatchableError as e:
      return err(e.msg)

  if numberTag.number != blk.number:
    return
      err("the downloaded block number doesn't match with the requested block number")

  # verify the block
  ?(await engine.verifyBlock(blk, fullTransactions))

  ok(blk)

proc getHeader*(
    engine: RpcVerificationEngine, blockHash: Hash32
): Future[Result[Header, string]] {.async: (raises: []).} =
  let cachedHeader = engine.headerStore.get(blockHash)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockHash = blockHash
  else:
    return ok(cachedHeader.get())

  # get the target block
  let blk =
    try:
      await engine.backend.eth_getBlockByHash(blockHash, false)
    except CatchableError as e:
      return err(e.msg)

  let header = convHeader(blk)

  if blockHash != blk.hash:
    return err("the blk.hash(downloaded) doesn't match with the provided hash")

  ?(await engine.verifyHeader(header, blockHash))

  ok(header)

proc getHeader*(
    engine: RpcVerificationEngine, blockTag: BlockTag
): Future[Result[Header, string]] {.async: (raises: []).} =
  let
    numberTag = engine.resolveBlockTag(blockTag).valueOr:
      return err(error)
    n = distinctBase(numberTag.number)
    cachedHeader = engine.headerStore.get(n)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockTag = blockTag
  else:
    return ok(cachedHeader.get())

  # get the target block
  let blk =
    try:
      await engine.backend.eth_getBlockByNumber(numberTag, false)
    except CatchableError as e:
      return err(e.msg)

  let header = convHeader(blk)

  if n != header.number:
    return
      err("the downloaded block number doesn't match with the requested block number")

  ?(await engine.verifyHeader(header, blk.hash))

  ok(header)
