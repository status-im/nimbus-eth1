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
  ./chain_db,
  ../../../db/core_db,
  ../../../db/fcu_db,
  ../../../db/storage_types,
  ../../../db/tx_frame_db,
  ../../../utils/utils

logScope:
  topics = "forked chain"

type
  StoredBlock = object
    header: Header
    hash: Hash32
    parentIndex: uint # zero for the base, otherwise parent slot + 1

  FcState = object
    numBlocks: uint
    base: uint
    latest: uint
    heads: seq[uint]
    pendingFCU: Hash32
    latestFinalized: FcuHashAndNumber
    fcuHead: FcuHashAndNumber
    fcuSafe: FcuHashAndNumber

# ------------------------------------------------------------------------------
# RLP serializer functions
# ------------------------------------------------------------------------------

func read(rlp: var Rlp, T: type FcState): T {.raises: [RlpError].} =
  rlp.tryEnterList()
  rlp.read(result.numBlocks)
  rlp.read(result.base)
  rlp.read(result.latest)
  rlp.read(result.heads)
  rlp.read(result.pendingFCU)
  rlp.read(result.latestFinalized)
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

proc stubAllTxFrames(fc: ForkedChainRef): Result[void, string] =
  # Should have no parent
  doAssert fc.base.parent.isNil

  # Base block shares its txFrame with the on-disk base
  fc.base.txFrame = fc.baseTxFrame

  # Base block always have finalized marker
  fc.base.finalize()

  for head in fc.heads:
    for it in ancestors(head):
      if it.txFrame.isNil.not:
        break
      if not fc.baseTxFrame.hasKey(txFrameKey(it.hash).toOpenArray):
        return err("corrupted FC: frame blob missing")
      let frame = fc.baseTxFrame.txFrameBegin()
      frame.spill()
      frame.blockHashFn = branchBlockHashFn(it.parent, it.number, it.hash)
      it.txFrame = frame

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

proc invalidateFcSnapshot*(db: CoreDbTxRef, keepFrames: bool): CoreDbRc[void] =
  # Indexed DAG entries are valid only as a complete snapshot. Once the
  # shared database changes, a restart must not load the old manifest.
  # Delete key by key: tx and receipt entries (`hashIndexKey`) carry no kind
  # prefix, so a range over the `fcState` kind byte would delete them too.
  # The manifest goes first. The block entries are numbered from 1 up and go
  # from the top down, so an interrupted run leaves 1..k for the next one.
  ?db.del(fcStateKey(0).toOpenArray)
  var n = 0'u64
  while ?db.hasKeyRc(fcStateKey(n + 1).toOpenArray):
    inc n
  for i in countdown(n, 1'u64):
    let key = fcStateKey(i)
    if not keepFrames:
      try:
        ?db.deleteTxFrame(rlp.decode(?db.get(key.toOpenArray), StoredBlock).hash)
      except RlpError:
        discard # the entry does not decode, its block hash is unknown
    ?db.del(key.toOpenArray)
  ok()

proc serialize*(fc: ForkedChainRef, txFrame: CoreDbTxRef): Result[void, CoreDbError] =
  # Keep serialization slots separate from the running chain's finalized flags.
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

  # KVT writes are immediate. Invalidate the old manifest before replacing
  # its entries, then publish the new manifest only after every frame is saved.
  ?txFrame.invalidateFcSnapshot(keepFrames = true)
  for i, b in blocks:
    let parentIndex = if b.parent.isNil: 0'u
                      else: slots.getOrDefault(b.parent.hash) + 1'u
    var encodedBlock = rlp.encode(StoredBlock(
      header: b.header, hash: b.hash, parentIndex: parentIndex))
    ?txFrame.put(blockIndexKey(i), encodedBlock)

  var encodedState = rlp.encode(state)
  ?txFrame.put(FcStateKey.toOpenArray, encodedState)

  # Block data is in the shared KVT already, the snapshot adds the DAG layout
  info "Saved block DAG snapshot to database",
    base=fc.base.number,
    baseHash=fc.base.hash.short,
    head=fc.fcuHead.number,
    headHash=fc.fcuHead.hash.short,
    finalized=fc.latestFinalized.number,
    finalizedHash=fc.latestFinalized.hash.short,
    latest=fc.latest.number,
    latestHash=fc.latest.hash.short,
    heads=fc.heads.toString,
    numBlocks=blocks.len,
    stateFrames=blocks.len - 1

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
  var parentIndices: seq[uint]
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
      let b = BlockRef(header: stored.header, hash: stored.hash)
      blocks.add b
      parentIndices.add stored.parentIndex
      restored.hashToBlock[b.hash] = b
  except RlpError as exc:
    return err(exc.msg)

  restored.base = blocks[state.base]
  restored.latest = blocks[state.latest]
  if restored.base.hash != fc.base.hash:
    return err("loaded baseHash != baseHash")

  for i, b in blocks:
    let parentIndex = parentIndices[i]
    if b == restored.base:
      if parentIndex != 0:
        return err("corrupted FC: base has a parent")
    else:
      if parentIndex == 0 or parentIndex > state.numBlocks:
        return err("corrupted FC: parent index out of range")
      let parent = blocks[parentIndex - 1]
      if b.number <= restored.base.number or parent.number >= b.number or
          b.number - parent.number != 1 or b.header.parentHash != parent.hash:
        return err("corrupted FC: inconsistent parent")
      b.parent = parent

  # Heads are the leaves of the tree, each listed once
  var isParent = newSeq[bool](blocks.len)
  for parentIndex in parentIndices:
    if parentIndex > 0:
      isParent[parentIndex - 1] = true
  var isHead = newSeq[bool](blocks.len)
  for h in state.heads:
    if isHead[h]:
      return err("corrupted FC: duplicate head")
    if isParent[h]:
      return err("corrupted FC: head has a child")
    isHead[h] = true
    restored.heads.add blocks[h]

  # A marker outside the tree can be valid, the finalized block may be known
  # before it is imported. Inside the tree it must carry its block's number.
  for (name, marker) in [("finalized", state.latestFinalized),
                         ("head", state.fcuHead), ("safe", state.fcuSafe)]:
    let b = restored.hashToBlock.getOrDefault(marker.hash)
    if b.isNil.not and b.number != marker.number:
      return err("corrupted FC: " & name & " number mismatch")

  restored.pendingFCU = state.pendingFCU
  restored.latestFinalized = state.latestFinalized
  restored.fcuHead = state.fcuHead
  restored.fcuSafe = state.fcuSafe

  ?restored.stubAllTxFrames()
  for b in blocks:
    if b.txFrame.isNil:
      return err("corrupted FC: block is not reachable from a head")

  # Blocks above base have no tx lookup on disk, rebuild it from their bodies
  for b in blocks:
    if b == restored.base:
      continue
    for encodedTx in b.txFrame.getBlockTransactionData(b.header.txRoot):
      b.txHashes.add keccak256(encodedTx)
    if b.txHashes.len == 0 and b.header.txRoot != EMPTY_ROOT_HASH:
      return err("corrupted FC: block transactions not found")

  restored.hashToBlock.withValue(restored.latestFinalized.hash, val):
    for it in loopNotFinalized(val[]):
      it.finalize()

  ?restored.restoreFrame(restored.latest, snapshot = true)

  fc.base = restored.base
  fc.latest = restored.latest
  fc.heads = move(restored.heads)
  fc.hashToBlock = move(restored.hashToBlock)
  fc.pendingFCU = restored.pendingFCU
  fc.latestFinalized = restored.latestFinalized
  fc.fcuHead = restored.fcuHead
  fc.fcuSafe = restored.fcuSafe
  loaded = true

  info "Loaded block DAG from database", base=fc.base.number,
    latest=fc.latest.number, numBlocks=fc.hashToBlock.len,
    heads=fc.heads.toString
  ok()
