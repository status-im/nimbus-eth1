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
): base.BlockNumber {.raises: [ValueError].} =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii()
    case tag
    of "latest":
      let hLatest = self.headerStore.latest()
      if hLatest.isSome:
        return hLatest.get().number
      else:
        raise newException(ValueError, "Couldn't get the latest block number from header store")
    else:
      raise newException(ValueError, "No support for block tag " & $blockTag)
  else:
    return base.BlockNumber(distinctBase(blockTag.number))

proc convHeader(blk: BlockObject): Header =
  let
    nonce = if blk.nonce.isSome: blk.nonce.get
            else: default(Bytes8)

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
    requestsHash: blk.requestsHash
  )

proc walkBlocks(
  self: VerifiedRpcProxy,
  sourceNum: base.BlockNumber,
  targetNum: base.BlockNumber,
  sourceHash: Hash32,
  targetHash: Hash32): Future[bool] {.async: (raises: [ValueError, CatchableError]).} =

  var nextHash = sourceHash
  info "starting block walk to verify", blockHash=targetHash

  # TODO: use batch calls to get all blocks at once by number
  for i in 0 ..< sourceNum - targetNum:
    # TODO: use a verified hash cache
    let blk = await self.rpcClient.eth_getBlockByHash(nextHash, false)
    info "getting next block", hash=nextHash, number=blk.number, remaining=distinctBase(blk.number) - targetNum

    if blk.parentHash == targetHash:
      return true

    nextHash = blk.parentHash

  return false

proc getBlockByHash*(
    self: VerifiedRpcProxy, blockHash: Hash32, fullTransactions: bool
): Future[BlockObject] {.async: (raises: [ValueError, CatchableError]).} =
  # get the target block
  let blk = await self.rpcClient.eth_getBlockByHash(blockHash, fullTransactions)
  let header = convHeader(blk)

  # verify header hash
  if header.rlpHash != blockHash:
    raise newException(ValueError, "hashed block header doesn't match with blk.hash(downloaded)")

  if blockHash != blk.hash:
    raise newException(ValueError, "the downloaded block hash doesn't match with the requested hash")

  let earliestHeader = self.headerStore.earliest.valueOr:
    raise newException(ValueError, "Syncing")

  # walk blocks backwards(time) from source to target
  let isLinked = await self.walkBlocks(earliestHeader.number, header.number, earliestHeader.parentHash, blockHash)

  if not isLinked:
    raise newException(ValueError, "the requested block is not part of the canonical chain")

  # verify transactions
  if fullTransactions:
    let verified = verifyTransactions(header.transactionsRoot, blk.transactions).valueOr:
      raise newException(ValueError, "error while verifying transactions root")
    if not verified:
      raise newException(ValueError, "transactions within the block do not yield the same transaction root")

  # verify withdrawals
  if blk.withdrawals.isSome():
    if blk.withdrawalsRoot.get() != orderedTrieRoot(blk.withdrawals.get()):
      raise newException(ValueError, "withdrawals within the block do not yield the same withdrawals root")

  return blk

proc getBlockByTag*(
    self: VerifiedRpcProxy, blockTag: BlockTag, fullTransactions: bool
): Future[BlockObject] {.async: (raises: [ValueError, CatchableError]).} =
  let n = self.resolveTag(blockTag)

  # get the target block
  let blk = await self.rpcClient.eth_getBlockByNumber(blockTag, false)
  let header = convHeader(blk)

  # verify header hash
  if header.rlpHash != blk.hash:
    raise newException(ValueError, "hashed block header doesn't match with blk.hash(downloaded)")

  if n != header.number:
    raise newException(ValueError, "the downloaded block number doesn't match with the requested block number")

  # get the source block
  let earliestHeader = self.headerStore.earliest.valueOr:
    raise newException(ValueError, "Syncing")

  # walk blocks backwards(time) from source to target
  let isLinked = await self.walkBlocks(earliestHeader.number, header.number, earliestHeader.parentHash, blk.hash)

  if not isLinked:
    raise newException(ValueError, "the requested block is not part of the canonical chain")

  # verify transactions
  if fullTransactions:
    let verified = verifyTransactions(header.transactionsRoot, blk.transactions).valueOr:
      raise newException(ValueError, "error while verifying transactions root")
    if not verified:
      raise newException(ValueError, "transactions within the block do not yield the same transaction root")

  # verify withdrawals
  if blk.withdrawals.isSome():
    if blk.withdrawalsRoot.get() != orderedTrieRoot(blk.withdrawals.get()):
      raise newException(ValueError, "withdrawals within the block do not yield the same withdrawals root")

  return blk

proc getHeaderByHash*(
    self: VerifiedRpcProxy, blockHash: Hash32
): Future[Header] {.async: (raises: [ValueError, CatchableError]).} =
  let cachedHeader = self.headerStore.get(blockHash)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockHash=blockHash
  else:
    return cachedHeader.get()

  # get the source block
  let earliestHeader = self.headerStore.earliest.valueOr:
    raise newException(ValueError, "Syncing")

  # get the target block
  let blk = await self.rpcClient.eth_getBlockByHash(blockHash, false)
  let header = convHeader(blk)

  # verify header hash
  if header.rlpHash != blk.hash:
    raise newException(ValueError, "hashed block header doesn't match with blk.hash(downloaded)")

  if blockHash != blk.hash:
    raise newException(ValueError, "the blk.hash(downloaded) doesn't match with the provided hash")

  # walk blocks backwards(time) from source to target
  let isLinked = await self.walkBlocks(earliestHeader.number, header.number, earliestHeader.parentHash, blockHash)

  if not isLinked:
    raise newException(ValueError, "the requested block is not part of the canonical chain")

  return header

proc getHeaderByTag*(
    self: VerifiedRpcProxy, blockTag: BlockTag
): Future[Header] {.async: (raises: [ValueError, CatchableError]).} =
  let
    n = self.resolveTag(blockTag)
    cachedHeader = self.headerStore.get(n)

  if cachedHeader.isNone():
    debug "did not find the header in the cache", blockTag=blockTag
  else:
    return cachedHeader.get()

  # get the source block
  let earliestHeader = self.headerStore.earliest.valueOr:
    raise newException(ValueError, "Syncing")

  # get the target block
  let blk = await self.rpcClient.eth_getBlockByNumber(blockTag, false)
  let header = convHeader(blk)

  # verify header hash
  if header.rlpHash != blk.hash:
    raise newException(ValueError, "hashed block header doesn't match with blk.hash(downloaded)")

  if n != header.number:
    raise newException(ValueError, "the downloaded block number doesn't match with the requested block number")

  # walk blocks backwards(time) from source to target
  let isLinked = await self.walkBlocks(earliestHeader.number, header.number, earliestHeader.parentHash, blk.hash)

  if not isLinked:
    raise newException(ValueError, "the requested block is not part of the canonical chain")

  return header
