# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/strutils,
  results,
  chronicles,
  web3/[eth_api_types, eth_api],
  json_rpc/[rpcproxy, rpcserver, rpcclient],
  eth/common/addresses,
  eth/common/eth_types_rlp,
  eth/trie/[ordered_trie, trie_defs],
  ../../execution_chain/beacon/web3_eth_conv,
  ../types,
  ../header_store,
  ./transactions

proc resolveBlockTag*(
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

  let numBlocks = sourceNum - targetNum
  if numBlocks > self.maxBlockWalk:
    return false

  for i in 0 ..< numBlocks:
    let nextHeader =
      if self.headerStore.contains(nextHash):
        self.headerStore.get(nextHash).get()
      else:
        let blk =
          try:
            await self.rpcClient.eth_getBlockByHash(nextHash, false)
          except:
            return false

        trace "getting next block",
          hash = nextHash,
          number = blk.number,
          remaining = distinctBase(blk.number) - targetNum

        convHeader(blk)

    if nextHeader.parentHash == targetHash:
      return true

    nextHash = nextHeader.parentHash

  return false

proc verifyHeader(
    self: VerifiedRpcProxy, header: Header, hash: Hash32
): Future[Result[bool, string]] {.async.} =
  # verify calculated hash with the requested hash
  if header.rlpHash != hash:
    return err("hashed block header doesn't match with blk.hash(downloaded)")

  let latestHeader = self.headerStore.latest.valueOr:
    return err("syncing")

  # walk blocks backwards(time) from source to target
  let isLinked = await self.walkBlocks(
    latestHeader.number, header.number, latestHeader.parentHash, hash
  )

  if not isLinked:
    return err("the requested block is not part of the canonical chain")

  return ok(true)

proc verifyBlock(
    self: VerifiedRpcProxy, blk: BlockObject, fullTransactions: bool
): Future[Result[bool, string]] {.async.} =
  let header = convHeader(blk)

  let status = await self.verifyHeader(header, blk.hash)

  if status.isErr():
    return err(status.error)

  # verify transactions
  if fullTransactions:
    let verified = verifyTransactions(header.transactionsRoot, blk.transactions).valueOr:
      return err(error)

  # verify withdrawals
  if blk.withdrawals.isSome():
    if blk.withdrawalsRoot.get() != orderedTrieRoot(blk.withdrawals.get()):
      return err("withdrawals within the block do not yield the same withdrawals root")

  return ok(true)

proc getBlock*(
    self: VerifiedRpcProxy, blockHash: Hash32, fullTransactions: bool
): Future[Result[eth_api_types.BlockObject, string]] {.async.} =
  # get the target block
  let blk =
    try:
      await self.rpcClient.eth_getBlockByHash(blockHash, fullTransactions)
    except CatchableError as e:
      return err(e.msg)

  # verify requested hash with the downloaded hash
  if blockHash != blk.hash:
    return err("the downloaded block hash doesn't match with the requested hash")

  # verify the block
  let status = await self.verifyBlock(blk, fullTransactions)

  if status.isErr():
    return err(status.error)

  return ok(blk)

proc getBlock*(
    self: VerifiedRpcProxy, blockTag: BlockTag, fullTransactions: bool
): Future[Result[BlockObject, string]] {.async.} =
  let n = self.resolveBlockTag(blockTag).valueOr:
    return err(error)

  # get the target block
  let blk =
    try:
      await self.rpcClient.eth_getBlockByNumber(blockTag, fullTransactions)
    except CatchableError as e:
      return err(e.msg)

  if n != distinctBase(blk.number):
    return
      err("the downloaded block number doesn't match with the requested block number")

  # verify the block
  let status = await self.verifyBlock(blk, fullTransactions)

  if status.isErr():
    return err(status.error)

  return ok(blk)

proc getHeader*(
    self: VerifiedRpcProxy, blockHash: Hash32
): Future[Result[Header, string]] {.async.} =
  let cachedHeader = self.headerStore.get(blockHash)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockHash = blockHash
  else:
    return ok(cachedHeader.get())

  # get the target block
  let blk =
    try:
      await self.rpcClient.eth_getBlockByHash(blockHash, false)
    except CatchableError as e:
      return err(e.msg)

  let header = convHeader(blk)

  if blockHash != blk.hash:
    return err("the blk.hash(downloaded) doesn't match with the provided hash")

  let status = await self.verifyHeader(header, blockHash)

  if status.isErr():
    return err(status.error)

  return ok(header)

proc getHeader*(
    self: VerifiedRpcProxy, blockTag: BlockTag
): Future[Result[Header, string]] {.async.} =
  let
    n = self.resolveBlockTag(blockTag).valueOr:
      return err(error)
    cachedHeader = self.headerStore.get(n)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockTag = blockTag
  else:
    return ok(cachedHeader.get())

  # get the target block
  let blk =
    try:
      await self.rpcClient.eth_getBlockByNumber(blockTag, false)
    except CatchableError as e:
      return err(e.msg)

  let header = convHeader(blk)

  if n != header.number:
    return
      err("the downloaded block number doesn't match with the requested block number")

  let status = await self.verifyHeader(header, blk.hash)

  if status.isErr():
    return err(status.error)

  return ok(header)
