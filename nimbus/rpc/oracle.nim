# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[hashes, algorithm, strutils],
  eth/eip1559,
  stew/keyed_queue,
  stew/endians2,
  results,
  ../transaction,
  ../common/common,
  ../core/eip4844

from ./rpc_types import
  Quantity,
  BlockTag,
  BlockIdentifierKind,
  FeeHistoryResult,
  FeeHistoryReward

from ./rpc_utils import headerFromTag

type
  # ProcessedFees contains the results of a processed block.
  ProcessedFees = ref object
    reward          : seq[UInt256]
    baseFee         : UInt256
    blobBaseFee     : UInt256
    nextBaseFee     : UInt256
    nextBlobBaseFee : UInt256
    gasUsedRatio    : float64
    blobGasUsedRatio: float64

  # BlockContent represents a single block for processing
  BlockContent = object
    blockNumber: uint64
    header     : BlockHeader
    txs        : seq[Transaction]
    receipts   : seq[Receipt]

  CacheKey = object
    number:      uint64
    percentiles: seq[byte]

  # txGasAndReward is sorted in ascending order based on reward
  TxGasAndReward = object
    gasUsed: uint64
    reward : UInt256

  BlockRange = object
    pendingBlock: Opt[uint64]
    lastBlock: uint64
    blocks: uint64

  Oracle* = ref object
    com: CommonRef
    maxHeaderHistory: uint64
    maxBlockHistory : uint64
    historyCache    : KeyedQueue[CacheKey, ProcessedFees]

{.push gcsafe, raises: [].}

func new*(_: type Oracle, com: CommonRef): Oracle =
  Oracle(
    com: com,
    maxHeaderHistory: 1024,
    maxBlockHistory: 1024,
    historyCache: KeyedQueue[CacheKey, ProcessedFees].init(),
  )

func hash*(x: CacheKey): Hash =
  var h: Hash = 0
  h = h !& hash(x.number)
  h = h !& hash(x.percentiles)
  result = !$h

func toBytes(list: openArray[float64]): seq[byte] =
  for x in list:
    result.add(cast[uint64](x).toBytesLE)

func calcBaseFee(com: CommonRef, bc: BlockContent): UInt256 =
  if com.isLondon((bc.blockNumber + 1).toBlockNumber):
    calcEip1599BaseFee(
      bc.header.gasLimit,
      bc.header.gasUsed,
      bc.header.baseFee)
  else:
    0.u256

# processBlock takes a blockFees structure with the blockNumber, the header and optionally
# the block field filled in, retrieves the block from the backend if not present yet and
# fills in the rest of the fields.
proc processBlock(oracle: Oracle, bc: BlockContent, percentiles: openArray[float64]): ProcessedFees =
  result = ProcessedFees(
    baseFee: bc.header.baseFee,
    blobBaseFee: getBlobBaseFee(bc.header.excessBlobGas.get(0'u64)),
    nextBaseFee: calcBaseFee(oracle.com, bc),
    nextBlobBaseFee: getBlobBaseFee(calcExcessBlobGas(bc.header)),
    gasUsedRatio: float64(bc.header.gasUsed) / float64(bc.header.gasLimit),
    blobGasUsedRatio: float64(bc.header.blobGasUsed.get(0'u64)) / float64(MAX_BLOB_GAS_PER_BLOCK)
  )

  if percentiles.len == 0:
    # rewards were not requested, return
    return

  if bc.receipts.len == 0 and bc.txs.len != 0:
    # log.Error("receipts are missing while reward percentiles are requested")
    return

  result.reward = newSeq[UInt256](percentiles.len)
  if bc.txs.len == 0:
    # return an all zero row if there are no transactions to gather data from
    return

  var
    sorter = newSeq[TxGasAndReward](bc.txs.len)
    prevUsed = 0.GasInt

  for i, tx in bc.txs:
    let
      reward = tx.effectiveGasTip(bc.header.fee)
      gasUsed = bc.receipts[i].cumulativeGasUsed - prevUsed
    sorter[i] = TxGasAndReward(
      gasUsed: gasUsed.uint64,
      reward: reward.u256
    )
    prevUsed = bc.receipts[i].cumulativeGasUsed


  sorter.sort(proc(a, b: TxGasAndReward): int =
    if a.reward >= b.reward: 1
    else: -1
  )

  var
    txIndex: int
    sumGasUsed = sorter[0].gasUsed

  for i, p in percentiles:
    let thresholdGasUsed = uint64(float64(bc.header.gasUsed) * p / 100.0'f64)
    while sumGasUsed < thresholdGasUsed and txIndex < bc.txs.len-1:
      inc txIndex
      sumGasUsed += sorter[txIndex].gasUsed

    result.reward[i] = sorter[txIndex].reward

# resolveBlockRange resolves the specified block range to absolute block numbers while also
# enforcing backend specific limitations. The pending block and corresponding receipts are
# also returned if requested and available.
# Note: an error is only returned if retrieving the head header has failed. If there are no
# retrievable blocks in the specified range then zero block count is returned with no error.
proc resolveBlockRange(oracle: Oracle, blockId: BlockTag, numBlocks: uint64): Result[BlockRange, string] =
  # Get the chain's current head.
  let
    headBlock = try:
                  oracle.com.db.getCanonicalHead()
                except CatchableError as exc:
                  return err(exc.msg)
    head = headBlock.blockNumber.truncate(uint64)

  var
    reqEnd: uint64
    blocks = numBlocks
    pendingBlock: Opt[uint64]

  if blockId.kind == bidNumber:
    reqEnd = blockId.number.uint64
    # Fail if request block is beyond the chain's current head.
    if head < reqEnd:
      return err("RequestBeyondHead: requested " & $reqEnd & ", head " & $head)
  else:
    # Resolve block tag.
    let tag = blockId.alias.toLowerAscii
    var resolved: BlockHeader
    if tag == "pending":
      try:
        resolved = headerFromTag(oracle.com.db, blockId)
        pendingBlock = Opt.some(resolved.blockNumber.truncate(uint64))
      except CatchableError:
        # Pending block not supported by backend, process only until latest block.
        resolved = headBlock
        # Update total blocks to return to account for this.
        dec blocks
    else:
      try:
        resolved = headerFromTag(oracle.com.db, blockId)
      except CatchableError as exc:
        return err(exc.msg)

    # Absolute number resolved.
    reqEnd = resolved.blockNumber.truncate(uint64)

  # If there are no blocks to return, short circuit.
  if blocks == 0:
    return ok(BlockRange())

  # Ensure not trying to retrieve before genesis.
  if reqEnd+1 < blocks:
    blocks = reqEnd + 1

  ok(BlockRange(
    pendingBlock:pendingBlock,
    lastBlock: reqEnd,
    blocks: blocks,
  ))

proc getBlockContent(oracle: Oracle,
                     blockNumber: uint64,
                     blockTag: uint64,
                     fullBlock: bool): Result[BlockContent, string] =
  var bc = BlockContent(
    blockNumber: blockNumber
  )

  let db = oracle.com.db
  try:
    bc.header = db.getBlockHeader(blockNumber.toblockNumber)
    for tx in db.getBlockTransactions(bc.header):
      bc.txs.add tx

    for rc in db.getReceipts(bc.header.receiptRoot):
      bc.receipts.add rc

    return ok(bc)
  except RlpError as exc:
    return err(exc.msg)
  except BlockNotFound as exc:
    return err(exc.msg)

type
  OracleResult = object
    reward          : seq[seq[UInt256]]
    baseFee         : seq[UInt256]
    blobBaseFee     : seq[UInt256]
    gasUsedRatio    : seq[float64]
    blobGasUsedRatio: seq[float64]
    firstMissing    : int

func init(_: type OracleResult, blocks: int): OracleResult =
  OracleResult(
    reward          : newSeq[seq[UInt256]](blocks),
    baseFee         : newSeq[UInt256](blocks+1),
    blobBaseFee     : newSeq[UInt256](blocks+1),
    gasUsedRatio    : newSeq[float64](blocks),
    blobGasUsedRatio: newSeq[float64](blocks),
    firstMissing    : blocks,
  )

proc addToResult(res: var OracleResult, i: int, fees: ProcessedFees) =
  if fees.isNil:
    # getting no block and no error means we are requesting into the future
    # (might happen because of a reorg)
    if i < res.firstMissing:
      res.firstMissing = i
  else:
    res.reward[i] = fees.reward
    res.baseFee[i] = fees.baseFee
    res.baseFee[i+1] = fees.nextBaseFee
    res.gasUsedRatio[i] = fees.gasUsedRatio
    res.blobBaseFee[i] = fees.blobBaseFee
    res.blobBaseFee[i+1] = fees.nextBlobBaseFee
    res.blobGasUsedRatio[i] = fees.blobGasUsedRatio


# FeeHistory returns data relevant for fee estimation based on the specified range of blocks.
# The range can be specified either with absolute block numbers or ending with the latest
# or pending block. Backends may or may not support gathering data from the pending block
# or blocks older than a certain age (specified in maxHistory). The first block of the
# actually processed range is returned to avoid ambiguity when parts of the requested range
# are not available or when the head has changed during processing this request.
# Three arrays are returned based on the processed blocks:
#   - reward: the requested percentiles of effective priority fees per gas of transactions in each
#     block, sorted in ascending order and weighted by gas used.
#   - baseFee: base fee per gas in the given block
#   - gasUsedRatio: gasUsed/gasLimit in the given block
#
# Note: baseFee includes the next block after the newest of the returned range, because this
# value can be derived from the newest block.
proc feeHistory*(oracle: Oracle,
                 blocks: uint64,
                 unresolvedLastBlock: BlockTag,
                 rewardPercentiles: openArray[float64]): Result[FeeHistoryResult, string] =

  var blocks = blocks
  if blocks < 1:
    # returning with no data and no error means there are no retrievable blocks
    return

  let maxFeeHistory = if rewardPercentiles.len == 0:
                        oracle.maxHeaderHistory
                      else:
                        oracle.maxBlockHistory

  if blocks > maxFeeHistory:
    # log.Warn("Sanitizing fee history length", "requested", blocks, "truncated", maxFeeHistory)
    blocks = maxFeeHistory

  for i, p in rewardPercentiles:
    if p < 0.0 or p > 100.0:
      return err("Invalid percentile: " & $p)

    if i > 0 and p <= rewardPercentiles[i-1]:
      return err("Invalid percentile: #" & $(i-1) &
        ":" & $rewardPercentiles[i-1] & " >= #" & $i & ":" & $p)

  let br = oracle.resolveBlockRange(unresolvedLastBlock, blocks).valueOr:
    return err(error)

  let
    oldestBlock = br.lastBlock + 1 - br.blocks
    percentileKey = rewardPercentiles.toBytes
    fullBlock = rewardPercentiles.len != 0

  var
    next = oldestBlock
    res = OracleResult.init(br.blocks.int)

  for i in 0..<blocks:
    # Retrieve the next block number to fetch
    let blockNumber = next
    inc next
    if blockNumber > br.lastBlock:
      break

    if br.pendingBlock.isSome and blockNumber >= br.pendingBlock.get:
      let
        bc = oracle.getBlockContent(blockNumber, br.pendingBlock.get, fullBlock).valueOr:
               return err(error)
        fees = oracle.processBlock(bc, rewardPercentiles)
      res.addToResult((blockNumber - oldestBlock).int, fees)
    else:
      let
        cacheKey = CacheKey(number: blockNumber, percentiles: percentileKey)
        fr = oracle.historyCache.lruFetch(cacheKey)

      if fr.isOk:
        res.addToResult((blockNumber - oldestBlock).int, fr.get)
      else:
        let bc = oracle.getBlockContent(blockNumber, blockNumber, fullBlock).valueOr:
          return err(error)
        let fees = oracle.processBlock(bc, rewardPercentiles)
        discard oracle.historyCache.lruAppend(cacheKey, fees, 2048)
        # send to results even if empty to guarantee that blocks items are sent in total
        res.addToResult((blockNumber - oldestBlock).int, fees)

  if res.firstMissing == 0:
    return ok(FeeHistoryResult())

  var historyResult: FeeHistoryResult

  if rewardPercentiles.len != 0:
    res.reward.setLen(res.firstMissing)
    historyResult.reward = some(system.move res.reward)
  else:
    historyResult.reward = none(seq[FeeHistoryReward])

  res.baseFee.setLen(res.firstMissing+1)
  res.gasUsedRatio.setLen(res.firstMissing)
  res.blobBaseFee.setLen(res.firstMissing+1)
  res.blobGasUsedRatio.setLen(res.firstMissing)

  historyResult.oldestBlock = Quantity oldestBlock
  historyResult.baseFeePerGas = system.move(res.baseFee)
  historyResult.baseFeePerBlobGas = system.move(res.blobBaseFee)
  historyResult.gasUsedRatio = system.move(res.gasUsedRatio)
  historyResult.blobGasUsedRatio = system.move(res.blobGasUsedRatio)

  ok(historyResult)

{.pop.}
