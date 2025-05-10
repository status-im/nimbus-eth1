# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/strutils,
  results,
  chronicles,
  web3/[primitives, eth_api_types, eth_api],
  json_rpc/[rpcproxy, rpcserver, rpcclient],
  eth/common/addresses,
  eth/common/eth_types_rlp,
  eth/trie/[hexary, ordered_trie, db, trie_defs],
  ../../execution_chain/beacon/web3_eth_conv,
  ../types,
  ../header_store,
  ./transactions

type BlockTag* = eth_api_types.RtBlockIdentifier

template rpcClient(vp: VerifiedRpcProxy): RpcClient =
  vp.proxy.getClient()

proc resolveTag(
    self: VerifiedRpcProxy, blockTag: BlockTag
): Result[base.BlockNumber, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii()
    case tag
    of "latest":
      let hLatest = self.headerStore.latest()
      if hLatest.isSome:
        return ok(hLatest.get().number)
      else:
        return err("Couldn't get the latest block number from header store")
    else:
      return err("No support for block tag " & $blockTag)
  else:
    return ok(base.BlockNumber(distinctBase(blockTag.number)))

proc convHeader(blk: eth_api_types.BlockObject): Header =
  let nonce =
    if blk.nonce.isSome:
      blk.nonce.get
    else:
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
    self: VerifiedRpcProxy,
    sourceNum: base.BlockNumber,
    targetNum: base.BlockNumber,
    sourceHash: Hash32,
    targetHash: Hash32,
): Future[bool] {.async: (raises: []).} =
  var nextHash = sourceHash
  info "starting block walk to verify", blockHash = targetHash

  # TODO: use batch calls to get all blocks at once by number
  for i in 0 ..< sourceNum - targetNum:
    # TODO: use a verified hash cache
    let blk =
      try:
        await self.rpcClient.eth_getBlockByHash(nextHash, false)
      except:
        # TODO: retry before failing?
        return false

    trace "getting next block",
      hash = nextHash,
      number = blk.number,
      remaining = distinctBase(blk.number) - targetNum

    if blk.parentHash == targetHash:
      return true

    nextHash = blk.parentHash

  return false

proc getBlockByHash*(
    self: VerifiedRpcProxy, blockHash: Hash32, fullTransactions: bool
): Future[Result[eth_api_types.BlockObject, string]] {.async: (raises: []).} =
  # get the target block
  let blk =
    try:
      await self.rpcClient.eth_getBlockByHash(blockHash, fullTransactions)
    except CatchableError as e:
      return err(e.msg)

  let header = convHeader(blk)

  # verify header hash
  if header.rlpHash != blockHash:
    return err("hashed block header doesn't match with blk.hash(downloaded)")

  if blockHash != blk.hash:
    return err("the downloaded block hash doesn't match with the requested hash")

  let earliestHeader = self.headerStore.earliest.valueOr:
    return err("syncing")

  # walk blocks backwards(time) from source to target
  let isLinked = await self.walkBlocks(
    earliestHeader.number, header.number, earliestHeader.parentHash, blockHash
  )

  if not isLinked:
    return err("the requested block is not part of the canonical chain")

  # verify transactions
  if fullTransactions:
    let verified = verifyTransactions(header.transactionsRoot, blk.transactions).valueOr:
      return err("error while verifying transactions root")
    if not verified:
      return err("transactions within the block do not yield the same transaction root")

  # verify withdrawals
  if blk.withdrawals.isSome():
    if blk.withdrawalsRoot.get() != orderedTrieRoot(blk.withdrawals.get()):
      return err("withdrawals within the block do not yield the same withdrawals root")

  return ok(blk)

proc getBlockByTag*(
    self: VerifiedRpcProxy, blockTag: BlockTag, fullTransactions: bool
): Future[Result[BlockObject, string]] {.async: (raises: []).} =
  let n = self.resolveTag(blockTag).valueOr:
    return err(error)

  # get the target block
  let blk =
    try:
      await self.rpcClient.eth_getBlockByNumber(blockTag, false)
    except CatchableError as e:
      return err(e.msg)

  let header = convHeader(blk)

  # verify header hash
  if header.rlpHash != blk.hash:
    return err("hashed block header doesn't match with blk.hash(downloaded)")

  if n != header.number:
    return
      err("the downloaded block number doesn't match with the requested block number")

  # get the source block
  let earliestHeader = self.headerStore.earliest.valueOr:
    return err("Syncing")

  # walk blocks backwards(time) from source to target
  let isLinked = await self.walkBlocks(
    earliestHeader.number, header.number, earliestHeader.parentHash, blk.hash
  )

  if not isLinked:
    return err("the requested block is not part of the canonical chain")

  # verify transactions
  if fullTransactions:
    let verified = verifyTransactions(header.transactionsRoot, blk.transactions).valueOr:
      return err("error while verifying transactions root")
    if not verified:
      return err("transactions within the block do not yield the same transaction root")

  # verify withdrawals
  if blk.withdrawals.isSome():
    if blk.withdrawalsRoot.get() != orderedTrieRoot(blk.withdrawals.get()):
      return err("withdrawals within the block do not yield the same withdrawals root")

  return ok(blk)

proc getHeaderByHash*(
    self: VerifiedRpcProxy, blockHash: Hash32
): Future[Result[Header, string]] {.async: (raises: []).} =
  let cachedHeader = self.headerStore.get(blockHash)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockHash = blockHash
  else:
    return ok(cachedHeader.get())

  # get the source block
  let earliestHeader = self.headerStore.earliest.valueOr:
    return err("Syncing")

  # get the target block
  let blk =
    try:
      await self.rpcClient.eth_getBlockByHash(blockHash, false)
    except CatchableError as e:
      return err(e.msg)

  let header = convHeader(blk)

  # verify header hash
  if header.rlpHash != blk.hash:
    return err("hashed block header doesn't match with blk.hash(downloaded)")

  if blockHash != blk.hash:
    return err("the blk.hash(downloaded) doesn't match with the provided hash")

  # walk blocks backwards(time) from source to target
  let isLinked = await self.walkBlocks(
    earliestHeader.number, header.number, earliestHeader.parentHash, blockHash
  )

  if not isLinked:
    return err("the requested block is not part of the canonical chain")

  return ok(header)

proc getHeaderByTag*(
    self: VerifiedRpcProxy, blockTag: BlockTag
): Future[Result[Header, string]] {.async: (raises: []).} =
  let
    n = self.resolveTag(blockTag).valueOr:
      return err(error)
    cachedHeader = self.headerStore.get(n)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockTag = blockTag
  else:
    return ok(cachedHeader.get())

  # get the source block
  let earliestHeader = self.headerStore.earliest.valueOr:
    return err("Syncing")

  # get the target block
  let blk =
    try:
      await self.rpcClient.eth_getBlockByNumber(blockTag, false)
    except CatchableError as e:
      return err(e.msg)

  let header = convHeader(blk)

  # verify header hash
  if header.rlpHash != blk.hash:
    return err("hashed block header doesn't match with blk.hash(downloaded)")

  if n != header.number:
    return
      err("the downloaded block number doesn't match with the requested block number")

  # walk blocks backwards(time) from source to target
  let isLinked = await self.walkBlocks(
    earliestHeader.number, header.number, earliestHeader.parentHash, blk.hash
  )

  if not isLinked:
    return err("the requested block is not part of the canonical chain")

  return ok(header)
