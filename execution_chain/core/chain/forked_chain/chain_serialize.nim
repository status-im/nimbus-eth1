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
    numBranches: uint
    baseBranch: uint
    activeBranch: uint
    pendingFCU: Hash32
    latestFinalizedBlockNumber: uint64
    txRecords: seq[TxRecord]
    fcuHead: FcuHashAndNumber
    fcuSafe: FcuHashAndNumber

# ------------------------------------------------------------------------------
# RLP serializer functions
# ------------------------------------------------------------------------------

proc append(w: var RlpWriter, bd: BlockDesc) =
  w.startList(2)
  w.append(bd.blk)
  w.append(bd.hash)

proc append(w: var RlpWriter, brc: BranchRef) =
  w.startList(2)
  let parentIndex = if brc.parent.isNil: 0'u
                    else: brc.parent.index + 1'u
  w.append(parentIndex)
  w.append(brc.blocks)

proc append(w: var RlpWriter, fc: ForkedChainRef) =
  w.startList(8)
  w.append(fc.branches.len.uint)
  w.append(fc.baseBranch.index)
  w.append(fc.activeBranch.index)
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

proc read(rlp: var Rlp, T: type BlockDesc): T {.raises: [RlpError].} =
  rlp.tryEnterList()
  result = T()
  rlp.read(result.blk)
  rlp.read(result.hash)

proc read(rlp: var Rlp, T: type BranchRef): T {.raises: [RlpError].} =
  rlp.tryEnterList()
  result = T()
  rlp.read(result.index)
  rlp.read(result.blocks)

proc read(rlp: var Rlp, T: type FcState): T {.raises: [RlpError].} =
  rlp.tryEnterList()
  rlp.read(result.numBranches)
  rlp.read(result.baseBranch)
  rlp.read(result.activeBranch)
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

template branchIndexKey(i: SomeInteger): openArray[byte] =
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
                 parent: BlockPos,
                 bd: var BlockDesc): Result[void, string] =
  let
    parentFrame = parent.txFrame
    txFrame = parentFrame.txFrameBegin

  var receipts = fc.processBlock(parent.header, txFrame, bd.blk, bd.hash, false).valueOr:
    txFrame.dispose()
    return err(error)

  fc.writeBaggage(bd.blk, bd.hash, txFrame, receipts)
  fc.updateSnapshot(bd.blk, txFrame)

  bd.txFrame = txFrame
  bd.receipts = move(receipts)

  ok()

proc replayBranch(fc: ForkedChainRef;
    parent: BlockPos;
    branch: BranchRef;
    start: int;): Result[void, string] =

  var parent = parent
  for i in start..<branch.len:
    ?fc.replayBlock(parent, branch.blocks[i])
    parent.index = i

  # Use the index as a flag, if index == 0,
  # it means the branch already replayed.
  branch.index = 0

  for brc in fc.branches:
    # Skip already replayed branch
    if brc.index == 0:
      continue

    if brc.parent == branch:
      doAssert(brc.tailNumber > branch.tailNumber)
      doAssert((brc.tailNumber - branch.tailNumber) > 0)
      parent.index = int(brc.tailNumber - branch.tailNumber - 1)
      ?fc.replayBranch(parent, brc, 0)

  ok()

proc replay(fc: ForkedChainRef): Result[void, string] =
  # Should have no parent
  doAssert fc.baseBranch.index == 0
  doAssert fc.baseBranch.parent.isNil

  # Receipts for base block are loaded from database
  # see `receiptsByBlockHash`
  fc.baseBranch.blocks[0].txFrame = fc.baseTxFrame

  # Replay, exclude base block, start from 1
  let parent = BlockPos(
    branch: fc.baseBranch
  )
  fc.replayBranch(parent, fc.baseBranch, 1)

proc reset(fc: ForkedChainRef, branches: sink seq[BranchRef]) =
  let baseBranch = branches[0]

  fc.baseBranch   = baseBranch
  fc.activeBranch = baseBranch
  fc.branches     = move(branches)
  fc.hashToBlock  = {baseBranch.tailHash: baseBranch.lastBlockPos}.toTable
  fc.pendingFCU   = zeroHash32
  fc.latestFinalizedBlockNumber = 0'u64
  fc.txRecords.clear()
  fc.fcuHead.reset()
  fc.fcuSafe.reset()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc serialize*(fc: ForkedChainRef, txFrame: CoreDbTxRef): Result[void, CoreDbError] =
  for i, brc in fc.branches:
    brc.index = uint i
  ?txFrame.put(FcStateKey.toOpenArray, rlp.encode(fc))
  for i, brc in fc.branches:
    ?txFrame.put(branchIndexKey(i), rlp.encode(brc))
  ok()

proc deserialize*(fc: ForkedChainRef): Result[void, string] =
  let state = fc.baseTxFrame.getState().valueOr:
    return err("Cannot find previous FC state in database")

  let prevBaseHash = fc.baseBranch.tailHash
  var
    branches = move(fc.branches)
    numBlocksStored = 0

  fc.branches.setLen(state.numBranches)
  try:
    for i in 0..<state.numBranches:
      let
        data = fc.baseTxFrame.get(branchIndexKey(i)).valueOr:
          return err("Cannot find branch data")
        branch = rlp.decode(data, BranchRef)
      fc.branches[i] = branch
      numBlocksStored += branch.len
  except RlpError as exc:
    fc.branches = move(branches)
    return err(exc.msg)

  fc.baseBranch = fc.branches[state.baseBranch]
  fc.activeBranch = fc.branches[state.activeBranch]
  fc.pendingFCU = state.pendingFCU
  fc.latestFinalizedBlockNumber = state.latestFinalizedBlockNumber
  fc.fcuHead = state.fcuHead
  fc.fcuSafe = state.fcuSafe

  info "Loading block DAG from database",
    base=fc.baseBranch.tailNumber,
    pendingFCU=fc.pendingFCU.short,
    resolvedFin=fc.latestFinalizedBlockNumber,
    canonicalHead=fc.fcuHead.number,
    safe=fc.fcuSafe.number,
    numBranches=state.numBranches,
    blocksStored=numBlocksStored,
    latestBlock=fc.baseBranch.tailNumber+numBlocksStored.uint64

  if numBlocksStored > 64:
    info "Please wait until DAG finish loading..."

  if fc.baseBranch.tailHash != prevBaseHash:
    fc.reset(branches)
    return err("loaded baseHash != baseHash")

  for tx in state.txRecords:
    fc.txRecords[tx.txHash] = (tx.blockHash, tx.blockNumber)

  for brc in fc.branches:
    if brc.index > 0:
      brc.parent = fc.branches[brc.index-1]

    for i in 0..<brc.len:
      fc.hashToBlock[brc.blocks[i].hash] = BlockPos(
        branch: brc,
        index : i,
      )

  fc.replay().isOkOr:
    fc.reset(branches)
    return err(error)

  fc.hashToBlock.withValue(fc.fcuHead.hash, val) do:
    let txFrame = val[].txFrame
    ?txFrame.setHead(val[].header, fc.fcuHead.hash)
    ?txFrame.fcuHead(fc.fcuHead.hash, fc.fcuHead.number)

  fc.hashToBlock.withValue(fc.fcuSafe.hash, val) do:
    let txFrame = val[].txFrame
    ?txFrame.fcuSafe(fc.fcuSafe.hash, fc.fcuSafe.number)

  fc.hashToBlock.withValue(fc.pendingFCU, val) do:
    let txFrame = val[].txFrame
    ?txFrame.fcuFinalized(fc.pendingFCU, fc.latestFinalizedBlockNumber)

  ok()
