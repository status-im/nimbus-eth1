# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  results,
  chronicles,
  eth/common/blocks_rlp,
  ./chain_desc,
  ./chain_branch,
  ./chain_private,
  ../../../db/core_db,
  ../../../db/fcu_db,
  ../../../db/storage_types,
  ../../../utils/utils

logScope:
  topics = "forked chain"

type
  TxRecord = object
    txHash: Hash32
    blockHash: Hash32
    blockNumber: uint64

  FcState = object
    numBlocks: uint
    base: uint
    latest: uint
    heads: seq[uint]
    pendingFCU: Hash32
    latestFinalizedBlockNumber: uint64
    txRecords: seq[TxRecord]
    fcuHead: FcuHashAndNumber
    fcuSafe: FcuHashAndNumber

# ------------------------------------------------------------------------------
# RLP serializer functions
# ------------------------------------------------------------------------------

proc append(w: var RlpWriter, b: BlockRef) =
  w.startList(3)
  w.append(b.blk)
  w.append(b.hash)
  let parentIndex = if b.parent.isNil: 0'u
                    else: b.parent.index + 1'u
  w.append(parentIndex)

proc append(w: var RlpWriter, fc: ForkedChainRef) =
  w.startList(9)
  w.append(fc.hashToBlock.len.uint)
  w.append(fc.base.index)
  w.append(fc.latest.index)

  var heads = newSeqOfCap[uint](fc.heads.len)
  for h in fc.heads:
    heads.add h.index

  w.append(heads)
  w.append(fc.pendingFCU)
  w.append(fc.latestFinalizedBlockNumber)
  w.startList(fc.txRecords.len)
  for k, v in fc.txRecords:
    w.append(TxRecord(
      txHash: k,
      blockHash: v[0],
      blockNumber: v[1],
    ))
  w.append(fc.fcuHead)
  w.append(fc.fcuSafe)

proc read(rlp: var Rlp, T: type BlockRef): T {.raises: [RlpError].} =
  rlp.tryEnterList()
  result = T()
  rlp.read(result.blk)
  rlp.read(result.hash)
  rlp.read(result.index)

proc read(rlp: var Rlp, T: type FcState): T {.raises: [RlpError].} =
  rlp.tryEnterList()
  rlp.read(result.numBlocks)
  rlp.read(result.base)
  rlp.read(result.latest)
  rlp.read(result.heads)
  rlp.read(result.pendingFCU)
  rlp.read(result.latestFinalizedBlockNumber)
  rlp.read(result.txRecords)
  rlp.read(result.fcuHead)
  rlp.read(result.fcuSafe)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

const
  # The state always use 0 index
  FcStateKey = fcStateKey 0

template blockIndexKey(i: SomeInteger): openArray[byte] =
  # We reuse the fcStateKey but +1
  fcStateKey((i+1).uint).toOpenArray

proc getState(db: CoreDbTxRef): Opt[FcState] =
  let data = db.get(FcStateKey.toOpenArray).valueOr:
    return err()

  # Ignore state decode error, might be from an earlier state version release
  try:
    return ok rlp.decode(data, FcState) # catch/accept rlp error
  except RlpError:
    discard

  err()

proc replayBlock(fc: ForkedChainRef;
                 parent: BlockRef,
                 blk: BlockRef): Result[void, string] =
  let
    parentFrame = parent.txFrame
    txFrame = parentFrame.txFrameBegin()

  # Set finalized to true in order to skip the stateroot check when replaying the
  # block because the blocks should have already been checked previously during
  # the initial block execution.
  var receipts = fc.processBlock(parent, txFrame, blk.blk, blk.hash, finalized = true).valueOr:
    txFrame.dispose()
    return err(error)

  fc.writeBaggage(blk.blk, blk.hash, txFrame, receipts)

  # Checkpoint creates a snapshot of ancestor changes in txFrame - it is an
  # expensive operation, specially when creating a new branch (ie when blk
  # is being applied to a block that is currently not a head).
  txFrame.checkpoint(blk.header.number, skipSnapshot = false)

  blk.txFrame = txFrame
  blk.receipts = move(receipts)

  ok()

proc replayBranch(fc: ForkedChainRef;
    parent: BlockRef;
    head: BlockRef;
    ): Result[void, string] =

  var blocks = newSeqOfCap[BlockRef](head.number - parent.number)
  for it in  ancestors(head):
    if it.number > parent.number:
      blocks.add it
    else:
      break

  var parent = parent
  for i in countdown(blocks.len-1, 0):
    ?fc.replayBlock(parent, blocks[i])
    parent = blocks[i]

  ok()

proc replay(fc: ForkedChainRef): Result[void, string] =
  # Should have no parent
  doAssert fc.base.parent.isNil

  # Receipts for base block are loaded from database
  # see `receiptsByBlockHash`
  fc.base.txFrame = fc.baseTxFrame

  # Base block always have finalized marker
  fc.base.finalize()

  for head in fc.heads:
    for it in ancestors(head):
      if it.txFrame.isNil.not:
        ?fc.replayBranch(it, head)
        break

  ok()

proc reset(fc: ForkedChainRef, base: BlockRef) =
  fc.base        = base
  fc.latest      = base
  fc.heads       = @[base]
  fc.hashToBlock = {base.hash: base}.toTable
  fc.pendingFCU  = zeroHash32
  fc.latestFinalizedBlockNumber = 0'u64
  fc.txRecords.clear()
  fc.fcuHead.reset()
  fc.fcuSafe.reset()

func toString(list: openArray[BlockRef]): string =
  result.add '['
  for i, b in list:
    result.add $(b.number)
    if i < list.len-1:
      result.add ','
  result.add ']'

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc serialize*(fc: ForkedChainRef, txFrame: CoreDbTxRef): Result[void, CoreDbError] =
  var i = 0
  for b in fc.hashToBlock.values:
    b.index = uint i
    inc i

  ?txFrame.put(FcStateKey.toOpenArray, rlp.encode(fc))

  for b in fc.hashToBlock.values:
    ?txFrame.put(blockIndexKey(b.index), rlp.encode(b))

  info "Blocks DAG written to database",
    base=fc.base.number,
    baseHash=fc.base.hash.short,
    latest=fc.latest.number,
    latestHash=fc.latest.hash.short,
    head=fc.fcuHead.number,
    headHash=fc.fcuHead.hash.short,
    finalized=fc.latestFinalizedBlockNumber,
    finalizedHash=fc.pendingFCU.short,
    blocksSerialized=fc.hashToBlock.len,
    heads=fc.heads.toString

  ok()

proc deserialize*(fc: ForkedChainRef): Result[void, string] =
  let state = fc.baseTxFrame.getState().valueOr:
    return err("Cannot find previous FC state in database")

  let prevBase = fc.base
  var blocks = newSeq[BlockRef](state.numBlocks)

  # Sanity Checks for the FC state
  if state.latest > state.numBlocks or
     state.base > state.numBlocks:
    warn "TODO: Inconsistent state found"
    fc.reset(prevBase)
    return err("Invalid state: latest block is greater than number of blocks")

  # Sanity Checks for all the heads in FC state
  for head in state.heads:
    if head > state.numBlocks:
      warn "TODO: Inconsistent state found"
      fc.reset(prevBase)
      return err("Invalid state: heads greater than number of blocks")

  try:
    for i in 0..<state.numBlocks:
      let
        data = fc.baseTxFrame.get(blockIndexKey(i)).valueOr:
          return err("Cannot find branch data")
        branch = rlp.decode(data, BlockRef)
      blocks[i] = branch
  except RlpError as exc:
    return err(exc.msg)

  fc.base = blocks[state.base]
  fc.latest = blocks[state.latest]

  fc.heads = newSeqOfCap[BlockRef](state.heads.len)
  for h in state.heads:
    fc.heads.add blocks[h]

  fc.pendingFCU = state.pendingFCU
  fc.latestFinalizedBlockNumber = state.latestFinalizedBlockNumber
  fc.fcuHead = state.fcuHead
  fc.fcuSafe = state.fcuSafe

  info "Loading block DAG from database",
    base=fc.base.number,
    pendingFCU=fc.pendingFCU.short,
    resolvedFin=fc.latestFinalizedBlockNumber,
    canonicalHead=fc.fcuHead.number,
    safe=fc.fcuSafe.number,
    numBlocks=state.numBlocks,
    heads=fc.heads.toString

  if state.numBlocks > 64:
    info "Please wait until DAG finish loading..."

  if fc.base.hash != prevBase.hash:
    fc.reset(prevBase)
    return err("loaded baseHash != baseHash")

  for tx in state.txRecords:
    fc.txRecords[tx.txHash] = (tx.blockHash, tx.blockNumber)

  for b in blocks:
    if b.index > 0:
      b.parent = blocks[b.index-1]
    fc.hashToBlock[b.hash] = b

  fc.replay().isOkOr:
    fc.reset(prevBase)
    return err(error)

  # All blocks should have replayed
  for b in blocks:
    if b.txFrame.isNil:
      fc.reset(prevBase)
      return err("corrupted FC serialization: deserialized node should have txFrame")

  fc.hashToBlock.withValue(fc.fcuHead.hash, val) do:
    let txFrame = val[].txFrame
    ?txFrame.setHead(val[].header, fc.fcuHead.hash)
    ?txFrame.fcuHead(fc.fcuHead.hash, fc.fcuHead.number)

  fc.hashToBlock.withValue(fc.fcuSafe.hash, val) do:
    let txFrame = val[].txFrame
    ?txFrame.fcuSafe(fc.fcuSafe.hash, fc.fcuSafe.number)

  fc.hashToBlock.withValue(fc.pendingFCU, val) do:
    # Restore finalized marker
    for it in loopNotFinalized(val[]):
      it.finalize()
    let txFrame = val[].txFrame
    ?txFrame.fcuFinalized(fc.pendingFCU, fc.latestFinalizedBlockNumber)

  ok()
