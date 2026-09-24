# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  results,
  chronicles,
  eth/common/blocks_rlp,
  ./chain_desc,
  ./chain_branch,
  ../../../db/core_db,
  ../../../db/fcu_db,
  ../../../db/storage_types,
  ../../../db/tx_frame_db,
  ./chain_db,
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
    latestFinalized: FcuHashAndNumber
    txRecords: seq[TxRecord]
    fcuHead: FcuHashAndNumber
    fcuSafe: FcuHashAndNumber

# ------------------------------------------------------------------------------
# RLP serializer functions
# ------------------------------------------------------------------------------

type
  StoredBlock = object
    header: Header
    hash: Hash32
    parentIndex: uint # zero for the base, otherwise parent slot + 1

func read(rlp: var Rlp, T: type FcState): T {.raises: [RlpError].} =
  rlp.tryEnterList()
  rlp.read(result.numBlocks)
  rlp.read(result.base)
  rlp.read(result.latest)
  rlp.read(result.heads)
  rlp.read(result.pendingFCU)
  rlp.read(result.latestFinalized)
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

proc loadBranchTxFrames(parent: BlockRef;
                       head: BlockRef;
                       srcBase: CoreDbTxRef): Result[void, string] =
  ## Walk the branch from `parent` (exclusive, txFrame already set) up to
  ## `head` (inclusive), materialising each block's txFrame from its
  ## persisted blob as a child of the previous frame.
  var blocks = newSeqOfCap[BlockRef](head.number - parent.number)
  for it in ancestors(head):
    if it.number > parent.number:
      blocks.add it
    else:
      break

  var p = parent
  for i in countdown(blocks.len-1, 0):
    let b = blocks[i]
    let frame = srcBase.loadTxFrameAsChild(p.txFrame, b.hash).valueOr:
      return err($error)
    b.txFrame = frame
    p = b

  ok()

proc loadAllTxFrames(fc: ForkedChainRef): Result[void, string] =
  # Should have no parent
  doAssert fc.base.parent.isNil

  # Base block shares its txFrame with the on-disk base
  fc.base.txFrame = fc.baseTxFrame

  # Base block always have finalized marker
  fc.base.finalize()

  for head in fc.heads:
    for it in ancestors(head):
      if it.txFrame.isNil.not:
        ?loadBranchTxFrames(it, head, fc.baseTxFrame)
        break

  ok()

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
  # Serialization slots must not overwrite BlockRef.index: it holds the
  # finalized marker used by the running chain.
  var slots = initTable[Hash32, uint]()
  var blocks: seq[BlockRef]
  for b in fc.hashToBlock.values:
    slots[b.hash] = uint(blocks.len)
    blocks.add b

  var state = FcState(
    numBlocks: uint(blocks.len),
    base: slots.getOrDefault(fc.base.hash),
    latest: slots.getOrDefault(fc.latest.hash),
    pendingFCU: fc.pendingFCU,
    latestFinalized: fc.latestFinalized,
    fcuHead: fc.fcuHead,
    fcuSafe: fc.fcuSafe)
  for h in fc.heads:
    state.heads.add slots.getOrDefault(h.hash)
  for hash, record in fc.txRecords:
    state.txRecords.add TxRecord(
      txHash: hash, blockHash: record[0], blockNumber: record[1])

  # KVT writes are immediate. Invalidate the old manifest before replacing
  # its entries, then publish the new manifest only after every frame is saved.
  ?txFrame.invalidateFcSnapshot(force = true)
  for i, b in blocks:
    let parentIndex = if b.parent.isNil: 0'u
                      else: slots.getOrDefault(b.parent.hash) + 1'u
    var encodedBlock = rlp.encode(StoredBlock(
      header: b.header, hash: b.hash, parentIndex: parentIndex))
    ?txFrame.putMove(blockIndexKey(i), encodedBlock)
    if b != fc.base:
      ?txFrame.storeTxFrame(b.txFrame, b.hash)

  var encodedState = rlp.encode(state)
  ?txFrame.putMove(FcStateKey.toOpenArray, encodedState)

  info "Blocks DAG written to database",
    base=fc.base.number,
    baseHash=fc.base.hash.short,
    latest=fc.latest.number,
    latestHash=fc.latest.hash.short,
    head=fc.fcuHead.number,
    headHash=fc.fcuHead.hash.short,
    finalizedNum=fc.latestFinalized.number,
    finalizedHash=fc.latestFinalized.hash.short,
    blocksSerialized=fc.hashToBlock.len,
    heads=fc.heads.toString

  ok()

proc deserialize*(fc: ForkedChainRef): Result[void, string] =
  let state = fc.baseTxFrame.getState().valueOr:
    return err("Cannot find previous FC state in database")

  if state.numBlocks == 0 or state.latest >= state.numBlocks or
      state.base >= state.numBlocks or state.heads.len == 0:
    return err("Invalid FC state: block index out of range")
  for head in state.heads:
    if head >= state.numBlocks:
      return err("Invalid FC state: head index out of range")

  # Build separately so a missing/corrupt frame cannot leave a partially
  # restored chain behind. Saved blobs remain available for another attempt.
  let restored = ForkedChainRef(baseTxFrame: fc.baseTxFrame)
  var blocks: seq[BlockRef]
  var loaded = false
  defer:
    if not loaded:
      for b in blocks:
        if b.txFrame != nil and b.txFrame != fc.baseTxFrame:
          b.txFrame.dispose()
        b.parent = nil

  try:
    for i in 0..<state.numBlocks:
      let data = fc.baseTxFrame.get(blockIndexKey(i)).valueOr:
        return err("Cannot find branch data")
      let stored = rlp.decode(data, StoredBlock)
      if stored.hash != stored.header.computeBlockHash():
        return err("corrupted FC: header hash mismatch")
      if restored.hashToBlock.hasKey(stored.hash):
        return err("corrupted FC: duplicate block")
      let b = BlockRef(header: stored.header, hash: stored.hash,
                       index: stored.parentIndex)
      blocks.add b
      restored.hashToBlock[b.hash] = b
  except RlpError as exc:
    return err(exc.msg)

  restored.base = blocks[state.base]
  restored.latest = blocks[state.latest]
  if restored.base.hash != fc.base.hash:
    return err("loaded baseHash != baseHash")

  for b in blocks:
    if b == restored.base:
      if b.index != 0:
        return err("corrupted FC: base has a parent")
    else:
      if b.index == 0 or b.index > state.numBlocks:
        return err("corrupted FC: parent index out of range")
      let parent = blocks[b.index - 1]
      if b.number <= restored.base.number or parent.number >= b.number or
          b.number - parent.number != 1 or b.header.parentHash != parent.hash:
        return err("corrupted FC: inconsistent parent")
      b.parent = parent
    b.index = 0

  for h in state.heads:
    restored.heads.add blocks[h]
  restored.pendingFCU = state.pendingFCU
  restored.latestFinalized = state.latestFinalized
  restored.fcuHead = state.fcuHead
  restored.fcuSafe = state.fcuSafe
  for tx in state.txRecords:
    if not restored.hashToBlock.hasKey(tx.blockHash):
      return err("corrupted FC: transaction refers to missing block")
    restored.txRecords[tx.txHash] = (tx.blockHash, tx.blockNumber)

  ?restored.loadAllTxFrames()
  for b in blocks:
    if b.txFrame.isNil:
      return err("corrupted FC: block is not reachable from a head")
    if b != restored.base and b.txFrame.aTx.blockNumber != Opt.some(b.number):
      return err("corrupted FC: frame block number mismatch")

  restored.hashToBlock.withValue(restored.latestFinalized.hash, val):
    for it in loopNotFinalized(val[]):
      it.finalize()

  fc.base = restored.base
  fc.latest = restored.latest
  fc.heads = move(restored.heads)
  fc.hashToBlock = move(restored.hashToBlock)
  fc.pendingFCU = restored.pendingFCU
  fc.latestFinalized = restored.latestFinalized
  fc.txRecords = move(restored.txRecords)
  fc.fcuHead = restored.fcuHead
  fc.fcuSafe = restored.fcuSafe
  loaded = true

  info "Loaded block DAG from database", base=fc.base.number,
    latest=fc.latest.number, numBlocks=fc.hashToBlock.len,
    heads=fc.heads.toString
  ok()
