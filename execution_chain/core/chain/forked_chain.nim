# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  chronicles,
  std/[tables, algorithm],
  ../../common,
  ../../db/core_db,
  ../../evm/types,
  ../../evm/state,
  ../validate,
  ../executor/process_block,
  ./forked_chain/[chain_desc, chain_branch]

from std/sequtils import mapIt

logScope:
  topics = "forked chain"

export
  BlockDesc,
  ForkedChainRef,
  common,
  core_db

const
  BaseDistance = 128

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc processBlock(c: ForkedChainRef,
                  parent: Header,
                  txFrame: CoreDbTxRef,
                  blk: Block,
                  blkHash: Hash32,
                  finalized: bool): Result[seq[Receipt], string] =
  template header(): Header =
    blk.header

  let vmState = BaseVMState()
  vmState.init(parent, header, c.com, txFrame)

  ?c.com.validateHeaderAndKinship(blk, vmState.parent, txFrame)

  # When processing a finalized block, we optimistically assume that the state
  # root will check out and delay such validation for when it's time to persist
  # changes to disk
  ?vmState.processBlock(
    blk,
    skipValidation = false,
    skipReceipts = false,
    skipUncles = true,
    skipStateRootCheck = finalized and not c.eagerStateRoot,
    taskpool = c.com.taskpool,
  )

  # We still need to write header to database
  # because validateUncles still need it
  ?txFrame.persistHeader(blkHash, header, c.com.startOfHistory)

  ok(move(vmState.receipts))

func updateBranch(c: ForkedChainRef,
         parent: BlockPos,
         blk: Block,
         blkHash: Hash32,
         txFrame: CoreDbTxRef,
         receipts: sink seq[Receipt]) =
  if parent.isHead:
    parent.appendBlock(blk, blkHash, txFrame, move(receipts))
    c.hashToBlock[blkHash] = parent.lastBlockPos
    c.activeBranch = parent.branch
    return

  let newBranch = branch(parent.branch, blk, blkHash, txFrame, move(receipts))
  c.hashToBlock[blkHash] = newBranch.lastBlockPos
  c.branches.add(newBranch)
  c.activeBranch = newBranch

proc writeBaggage(c: ForkedChainRef,
        blk: Block, blkHash: Hash32,
        txFrame: CoreDbTxRef,
        receipts: openArray[Receipt]) =
  template header(): Header =
    blk.header

  txFrame.persistTransactions(header.number, header.txRoot, blk.transactions)
  txFrame.persistReceipts(header.receiptsRoot, receipts)
  discard txFrame.persistUncles(blk.uncles)
  if blk.withdrawals.isSome:
    txFrame.persistWithdrawals(
      header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
      blk.withdrawals.get)

proc validateBlock(c: ForkedChainRef,
          parent: BlockPos,
          blk: Block, finalized: bool): Result[void, string] =
  let blkHash = blk.header.blockHash

  if c.hashToBlock.hasKey(blkHash):
    # Block exists, just return
    return ok()

  let
    parentFrame = parent.txFrame
    txFrame = parentFrame.txFrameBegin

  # TODO shortLog-equivalent for eth types
  debug "Validating block",
    blkHash, blk = (
      parentHash: blk.header.parentHash,
      coinbase: blk.header.coinbase,
      stateRoot: blk.header.stateRoot,
      transactionsRoot: blk.header.transactionsRoot,
      receiptsRoot: blk.header.receiptsRoot,
      number: blk.header.number,
      gasLimit: blk.header.gasLimit,
      gasUsed: blk.header.gasUsed,
      nonce: blk.header.nonce,
      baseFeePerGas: blk.header.baseFeePerGas,
      withdrawalsRoot: blk.header.withdrawalsRoot,
      blobGasUsed: blk.header.blobGasUsed,
      excessBlobGas: blk.header.excessBlobGas,
      parentBeaconBlockRoot: blk.header.parentBeaconBlockRoot,
      requestsHash: blk.header.requestsHash,
    )

  var receipts = c.processBlock(parent.header, txFrame, blk, blkHash, finalized).valueOr:
    txFrame.dispose()
    return err(error)

  c.writeBaggage(blk, blkHash, txFrame, receipts)

  let pos = c.lastSnapshotPos
  c.lastSnapshotPos = (c.lastSnapshotPos + 1) mod c.lastSnapshots.len
  if not isNil(c.lastSnapshots[pos]):
    # Put a cap on frame memory usage by clearing out the oldest snapshots -
    # this works at the expense of making building on said branches slower.
    # 10 is quite arbitrary.
    c.lastSnapshots[pos].clearSnapshot()
    c.lastSnapshots[pos] = nil

  # Block fully written to txFrame, mark it as such
  # Checkpoint creates a snapshot of ancestor changes in txFrame - it is an
  # expensive operation, specially when creating a new branch (ie when blk
  # is being applied to a block that is currently not a head)
  txFrame.checkpoint(blk.header.number)

  c.lastSnapshots[pos] = txFrame

  c.updateBranch(parent, blk, blkHash, txFrame, move(receipts))

  for i, tx in blk.transactions:
    c.txRecords[rlpHash(tx)] = (blkHash, uint64(i))

  ok()

func findHeadPos(c: ForkedChainRef, hash: Hash32): Result[BlockPos, string] =
  ## Find the `BlockPos` that contains the block relative to the
  ## argument `hash`.
  ##
  c.hashToBlock.withValue(hash, val) do:
    return ok(val[])
  do:
    return err("Block hash is not part of any active chain")

func findFinalizedPos(
    c: ForkedChainRef;
    itHash: Hash32;
    head: BlockPos,
      ): Result[BlockPos, string] =
  ## Find header for argument `itHash` on argument `head` ancestor chain.
  ##

  # OK, new base stays on the argument head branch.
  # ::
  #         - B3 - B4 - B5 - B6
  #       /              ^    ^
  # A1 - A2 - A3         |    |
  #                      head CCH
  #
  # A1, A2, B3, B4, B5: valid
  # A3, B6: invalid

  # Find `itHash` on the ancestor lineage of `head`
  c.hashToBlock.withValue(itHash, loc):
    if loc[].number > head.number:
      return err("Invalid finalizedHash: block is newer than head block")

    var
      branch = head.branch
      prevBranch = BranchRef(nil)

    while not branch.isNil:
      if branch == loc[].branch:
        if prevBranch.isNil.not and
           loc[].number >= prevBranch.tailNumber:
          break # invalid
        return ok(loc[])

      prevBranch = branch
      branch = branch.parent

  err("Invalid finalizedHash: block not in argument head ancestor lineage")

func calculateNewBase(
    c: ForkedChainRef;
    finalized: BlockPos;
    head: BlockPos;
      ): BlockPos =
  ## It is required that the `finalized` argument is on the `head` chain, i.e.
  ## it ranges beween `c.baseBranch.tailNumber` and
  ## `head.branch.headNumber`.
  ##
  ## The function returns a BlockPos containing a new base position. It is
  ## calculated as follows.
  ##
  ## Starting at the argument `head.branch` searching backwards, the new base
  ## is the position of the block with number `finalized`.
  ##
  ## Before searching backwards, the `finalized` argument might be adjusted
  ## and made smaller so that a minimum distance to the head on the cursor arc
  ## applies.
  ##
  # It's important to have base at least `baseDistance` behind head
  # so we can answer state queries about history that deep.
  let target = min(finalized.number,
    max(head.number, c.baseDistance) - c.baseDistance)

  # Do not update base.
  if target <= c.baseBranch.tailNumber:
    return BlockPos(branch: c.baseBranch)

  if target >= head.branch.tailNumber:
    # OK, new base stays on the argument head branch.
    # ::
    #                  - B3 - B4 - B5 - B6
    #                /         ^    ^    ^
    #   base - A1 - A2 - A3    |    |    |
    #                          |    head CCH
    #                          |
    #                          target
    #
    return BlockPos(
      branch: head.branch,
      index : int(target - head.branch.tailNumber)
    )

  # The new base (aka target) falls out of the argument head branch,
  # ending up somewhere on a parent branch.
  # ::
  #                  - B3 - B4 - B5 - B6
  #                /              ^    ^
  #   base - A1 - A2 - A3         |    |
  #           ^                   head CCH
  #           |
  #           target
  #
  # base will not move to A3 onward for this iteration
  var branch = head.branch.parent
  while not branch.isNil:
    if target >= branch.tailNumber:
      return BlockPos(
        branch: branch,
        index : int(target - branch.tailNumber)
      )
    branch = branch.parent

  doAssert(false, "Unreachable code, finalized block outside canonical chain")

proc removeBlockFromCache(c: ForkedChainRef, bd: BlockDesc) =
  c.hashToBlock.del(bd.hash)
  for tx in bd.blk.transactions:
    c.txRecords.del(rlpHash(tx))

  for v in c.lastSnapshots.mitems():
    if v == bd.txFrame:
      v = nil

  bd.txFrame.dispose()

proc updateHead(c: ForkedChainRef, head: BlockPos) =
  ## Update head if the new head is different from current head.
  ## All branches with block number greater than head will be removed too.

  c.activeBranch = head.branch

  # Pruning if necessary
  # ::
  #                       - B5 - B6 - B7 - B8
  #                    /
  #   A1 - A2 - A3 - [A4] - A5 - A6
  #         \                \
  #           - C3 - C4        - D6 - D7
  #
  # A4 is head
  # 'D' and 'A5' onward will be removed
  # 'C' and 'B' will stay

  let headNumber = head.number
  var i = 0
  while i < c.branches.len:
    let branch = c.branches[i]

    # Any branches with block number greater than head+1 should be removed.
    if branch.tailNumber > headNumber + 1:
      for i in countdown(branch.blocks.len-1, 0):
        c.removeBlockFromCache(branch.blocks[i])
      c.branches.del(i)
      # no need to increment i when we delete from c.branches.
      continue

    inc i

  # Maybe the current active chain is longer than canonical chain,
  # trim the branch.
  for i in countdown(head.branch.len-1, head.index+1):
    c.removeBlockFromCache(head.branch.blocks[i])

  head.branch.blocks.setLen(head.index+1)
  head.txFrame.setHead(head.branch.headHeader,
    head.branch.headHash).expect("OK")

proc updateFinalized(c: ForkedChainRef, finalized: BlockPos) =
  # Pruning
  # ::
  #                       - B5 - B6 - B7 - B8
  #                    /
  #   A1 - A2 - A3 - [A4] - A5 - A6
  #         \                \
  #           - C3 - C4        - D6 - D7
  #
  # A4 is finalized
  # 'B', 'D', and A5 onward will stay
  # 'C' will be removed

  func sameLineage(brc: BranchRef, line: BranchRef): bool =
    var branch = line
    while not branch.isNil:
      if branch == brc:
        return true
      branch = branch.parent

  let finalizedNumber = finalized.number
  var i = 0
  while i < c.branches.len:
    let branch = c.branches[i]

    # Any branches with tail block number less or equal
    # than finalized should be removed.
    if not branch.sameLineage(finalized.branch) and branch.tailNumber <= finalizedNumber:
      for i in countdown(branch.blocks.len-1, 0):
        c.removeBlockFromCache(branch.blocks[i])
      c.branches.del(i)
      # no need to increment i when we delete from c.branches.
      continue

    inc i

  let txFrame = finalized.txFrame
  txFrame.finalizedHeaderHash(finalized.hash)

proc updateBase(c: ForkedChainRef, newBase: BlockPos) =
  ##
  ##     A1 - A2 - A3          D5 - D6
  ##    /                     /
  ## base - B1 - B2 - [B3] - B4 - B5
  ##         \          \
  ##          C2 - C3    E4 - E5
  ##
  ## where `B1..B5` is the `newBase.branch` arc and `[B5]` is the `newBase.headNumber`.
  ##
  ## The `base` will be moved to position `[B3]`.
  ## Both chains `A` and `C` have be removed by updateFinalized.
  ## `D` and `E`, and `B4` onward will stay.
  ## B1, B2, B3 will be persisted to DB and removed from FC.

  # Cleanup in-memory blocks starting from newBase backward
  # e.g. B3 backward. Switch to parent branch if needed.

  template disposeBlocks(number, branch) =
    let tailNumber = branch.tailNumber
    while number >= tailNumber:
      c.removeBlockFromCache(branch.blocks[number - tailNumber])
      inc count

      if number == 0:
        # Don't go below genesis
        break
      dec number

  let
    # Cache to prevent crash after we shift
    # the blocks
    newBaseHash = newBase.hash

  var
    branch = newBase.branch
    number = newBase.number - 1
    count  = 0

  let nextIndex  = int(newBase.number - branch.tailNumber)

  # Persist the new base block - this replaces the base tx in coredb!
  c.com.db.persist(newBase.txFrame, Opt.some(newBase.blk.header.stateRoot))
  c.baseTxFrame = newBase.txFrame

  disposeBlocks(number, branch)

  # Update base if it indeed changed
  if nextIndex > 0:
    # Only remove blocks with number lower than newBase.number
    var blocks = newSeqOfCap[BlockDesc](branch.len-nextIndex)
    for i in nextIndex..<branch.len:
      blocks.add branch.blocks[i]

    # Update hashToBlock index
    for i in 0..<blocks.len:
      c.hashToBlock[blocks[i].hash] = BlockPos(
        branch: branch,
        index : i
      )
    branch.blocks = move(blocks)

  # Older branches will gone
  branch = branch.parent
  while not branch.isNil:
    disposeBlocks(number, branch)

    for i, brc in c.branches:
      if brc == branch:
        c.branches.del(i)
        break

    branch = branch.parent

  # Update base branch
  c.baseBranch = newBase.branch
  c.baseBranch.parent = nil

  # Log only if more than one block persisted
  # This is to avoid log spamming, during normal operation
  # of the client following the chain
  # When multiple blocks are persisted together, it's mainly
  # during `beacon sync` or `nrpc sync`
  if count > 1:
    notice "Finalized blocks persisted",
      numberOfBlocks = count,
      baseNumber = c.baseBranch.tailNumber,
      baseHash = c.baseBranch.tailHash.short
  else:
    debug "Finalized blocks persisted",
      numberOfBlocks = count,
      target = newBaseHash.short,
      baseNumber = c.baseBranch.tailNumber,
      baseHash = c.baseBranch.tailHash.short

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type ForkedChainRef;
    com: CommonRef;
    baseDistance = BaseDistance.uint64;
    eagerStateRoot = false;
      ): T =
  ## Constructor that uses the current database ledger state for initialising.
  ## This state coincides with the canonical head that would be used for
  ## setting up the descriptor.
  ##
  ## With `ForkedChainRef` based import, the canonical state lives only inside
  ## a level one database transaction. Thus it will readily be available on the
  ## running system with tools such as `getCanonicalHead()`. But it will never
  ## be saved on the database.
  ##
  ## This constructor also works well when resuming import after running
  ## `persistentBlocks()` used for `Era1` or `Era` import.
  ##
  let
    baseTxFrame = com.db.baseTxFrame()
    base = baseTxFrame.getSavedStateBlockNumber
    baseHash = baseTxFrame.getBlockHash(base).expect("baseHash exists")
    baseHeader = baseTxFrame.getBlockHeader(baseHash).expect("base header exists")
    baseBranch = branch(baseHeader, baseHash, baseTxFrame)

  T(com:             com,
    baseBranch:      baseBranch,
    activeBranch:    baseBranch,
    branches:        @[baseBranch],
    hashToBlock:     {baseHash: baseBranch.lastBlockPos}.toTable,
    baseTxFrame:     baseTxFrame,
    baseDistance:    baseDistance)

proc importBlock*(c: ForkedChainRef, blk: Block, finalized = false): Result[void, string] =
  ## Try to import block to canonical or side chain.
  ## return error if the block is invalid
  ##
  ## `finalized` should be set to true for blocks that are known to be finalized
  ## already per the latest fork choice update from the consensus client, for
  ## example by following the header chain back from the fcu hash - in such
  ## cases, we perform state root checking in bulk while writing the state to
  ## disk (instead of once for every block).
  template header(): Header =
    blk.header

  c.hashToBlock.withValue(header.parentHash, bd) do:
    # TODO: If engine API keep importing blocks
    # but not finalized it, e.g. current chain length > StagedBlocksThreshold
    # We need to persist some of the in-memory stuff
    # to a "staging area" or disk-backed memory but it must not afect `base`.
    # `base` is the point of no return, we only update it on finality.

    ?c.validateBlock(bd[], blk, finalized)
  do:
    # If it's parent is an invalid block
    # there is no hope the descendant is valid
    debug "Parent block not found",
      blockHash = header.blockHash.short,
      parentHash = header.parentHash.short
    return err("Block is not part of valid chain")

  ok()

proc forkChoice*(c: ForkedChainRef,
                 headHash: Hash32,
                 finalizedHash: Hash32): Result[void, string] =
  if headHash == c.activeBranch.headHash and finalizedHash == zeroHash32:
    # Do nothing if the new head already our current head
    # and there is no request to new finality.
    return ok()

  let
    # Find the unique branch where `headHash` is a member of.
    head = ?c.findHeadPos(headHash)
    # Finalized block must be parent or on the new canonical chain which is
    # represented by `head`.
    finalized = ?c.findFinalizedPos(finalizedHash, head)

  # Head maybe moved backward or moved to other branch.
  c.updateHead(head)

  if finalizedHash == zeroHash32:
    # skip updateBase and updateFinalized if finalizedHash is zero.
    return ok()

  c.updateFinalized(finalized)

  let newBase = c.calculateNewBase(finalized, head)
  if newBase.hash == c.baseBranch.tailHash:
    # The base is not updated, return.
    return ok()

  # Cache the base block number, updateBase might
  # alter the BlockPos.index
  let newBaseNumber = newBase.number

  # At this point head.number >= base.number.
  # At this point finalized.number is <= head.number,
  # and possibly switched to other chain beside the one with head.
  doAssert(finalized.number <= head.number)
  doAssert(newBaseNumber <= finalized.number)
  c.updateBase(newBase)

  ok()

func haveBlockAndState*(c: ForkedChainRef, blockHash: Hash32): bool =
  ## Blocks still in memory with it's txFrame
  c.hashToBlock.hasKey(blockHash)

func txFrame*(c: ForkedChainRef, blockHash: Hash32): CoreDbTxRef =
  if blockHash == c.baseBranch.tailHash:
    return c.baseTxFrame

  c.hashToBlock.withValue(blockHash, loc) do:
    return loc[].txFrame

  c.baseTxFrame

func baseTxFrame*(c: ForkedChainRef): CoreDbTxRef =
  c.baseTxFrame

func txFrame*(c: ForkedChainRef, header: Header): CoreDbTxRef =
  c.txFrame(header.blockHash())

func latestTxFrame*(c: ForkedChainRef): CoreDbTxRef =
  c.activeBranch.headTxFrame

func com*(c: ForkedChainRef): CommonRef =
  c.com

func db*(c: ForkedChainRef): CoreDbRef =
  c.com.db

func latestHeader*(c: ForkedChainRef): Header =
  c.activeBranch.headHeader

func latestNumber*(c: ForkedChainRef): BlockNumber =
  c.activeBranch.headNumber

func latestHash*(c: ForkedChainRef): Hash32 =
  c.activeBranch.headHash

func baseNumber*(c: ForkedChainRef): BlockNumber =
  c.baseBranch.tailNumber

func baseHash*(c: ForkedChainRef): Hash32 =
  c.baseBranch.tailHash

func txRecords*(c: ForkedChainRef, txHash: Hash32): (Hash32, uint64) =
  c.txRecords.getOrDefault(txHash, (Hash32.default, 0'u64))

func isInMemory*(c: ForkedChainRef, blockHash: Hash32): bool =
  c.hashToBlock.hasKey(blockHash)

func memoryBlock*(c: ForkedChainRef, blockHash: Hash32): BlockDesc =
  c.hashToBlock.withValue(blockHash, loc):
    return loc.branch.blocks[loc.index]
  # Return default(BlockDesc)

func memoryTransaction*(c: ForkedChainRef, txHash: Hash32): Opt[(Transaction, BlockNumber)] =
  let (blockHash, index) = c.txRecords.getOrDefault(txHash, (Hash32.default, 0'u64))
  c.hashToBlock.withValue(blockHash, loc) do:
    return Opt.some( (loc[].tx(index), loc[].number) )
  return Opt.none((Transaction, BlockNumber))

func memoryTxHashesForBlock*(c: ForkedChainRef, blockHash: Hash32): Opt[seq[Hash32]] =
  var cachedTxHashes = newSeq[(Hash32, uint64)]()
  for txHash, (blkHash, txIdx) in c.txRecords.pairs:
    if blkHash == blockHash:
      cachedTxHashes.add((txHash, txIdx))

  if cachedTxHashes.len <= 0:
    return Opt.none(seq[Hash32])

  cachedTxHashes.sort(proc(a, b: (Hash32, uint64)): int =
      cmp(a[1], b[1])
    )
  Opt.some(cachedTxHashes.mapIt(it[0]))

proc latestBlock*(c: ForkedChainRef): Block =
  if c.activeBranch.headNumber == c.baseBranch.tailNumber:
    # It's a base block
    return c.baseTxFrame.getEthBlock(c.activeBranch.headHash).expect("cursorBlock exists")
  c.activeBranch.blocks[^1].blk

proc headerByNumber*(c: ForkedChainRef, number: BlockNumber): Result[Header, string] =
  if number > c.activeBranch.headNumber:
    return err("Requested block number not exists: " & $number)

  if number < c.baseBranch.tailNumber:
    return c.baseTxFrame.getBlockHeader(number)

  var branch = c.activeBranch
  while not branch.isNil:
    if number >= branch.tailNumber:
      return ok(branch.blocks[number - branch.tailNumber].blk.header)
    branch = branch.parent

  err("Header not found, number = " & $number)

proc headerByHash*(c: ForkedChainRef, blockHash: Hash32): Result[Header, string] =
  c.hashToBlock.withValue(blockHash, loc):
    return ok(loc[].header)
  c.baseTxFrame.getBlockHeader(blockHash)

proc txDetailsByTxHash*(c: ForkedChainRef, txHash: Hash32): Result[(Hash32, uint64), string] =
  if c.txRecords.hasKey(txHash):
    let (blockHash, txid) = c.txRecords(txHash)
    return ok((blockHash, txid))

  let
    txDetails = ?c.baseTxFrame.getTransactionKey(txHash)
    header = ?c.headerByNumber(txDetails.blockNumber)
    blockHash = header.blockHash
  return ok((blockHash, txDetails.index))

proc blockByHash*(c: ForkedChainRef, blockHash: Hash32): Result[Block, string] =
  # used by getPayloadBodiesByHash
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/shanghai.md#specification-3
  # 4. Client software MAY NOT respond to requests for finalized blocks by hash.
  c.hashToBlock.withValue(blockHash, loc):
    return ok(loc[].blk)
  c.baseTxFrame.getEthBlock(blockHash)

proc blockBodyByHash*(c: ForkedChainRef, blockHash: Hash32): Result[BlockBody, string] =
  c.hashToBlock.withValue(blockHash, loc):
    let blk = loc[].blk
    return ok(BlockBody(
      transactions: blk.transactions,
      uncles: blk.uncles,
      withdrawals: blk.withdrawals,
    ))
  c.baseTxFrame.getBlockBody(blockHash)

proc blockByNumber*(c: ForkedChainRef, number: BlockNumber): Result[Block, string] =
  if number > c.activeBranch.headNumber:
    return err("Requested block number not exists: " & $number)

  if number <= c.baseBranch.tailNumber:
    return c.baseTxFrame.getEthBlock(number)

  var branch = c.activeBranch
  while not branch.isNil:
    if number >= branch.tailNumber:
      return ok(branch.blocks[number - branch.tailNumber].blk)
    branch = branch.parent

  err("Block not found, number = " & $number)

proc blockHeader*(c: ForkedChainRef, blk: BlockHashOrNumber): Result[Header, string] =
  if blk.isHash:
    return c.headerByHash(blk.hash)
  c.headerByNumber(blk.number)

proc receiptsByBlockHash*(c: ForkedChainRef, blockHash: Hash32): Result[seq[Receipt], string] =
  c.hashToBlock.withValue(blockHash, loc):
    return ok(loc[].receipts)

  let header = c.baseTxFrame.getBlockHeader(blockHash).valueOr:
    return err("Block header not found")

  c.baseTxFrame.getReceipts(header.receiptsRoot)

func blockFromBaseTo*(c: ForkedChainRef, number: BlockNumber): seq[Block] =
  # return block in reverse order
  var branch = c.activeBranch
  while not branch.isNil:
    for i in countdown(branch.len-1, 0):
      result.add(branch.blocks[i].blk)
    branch = branch.parent

func equalOrAncestorOf*(c: ForkedChainRef, blockHash: Hash32, ancestorHash: Hash32): bool =
  if blockHash == ancestorHash:
    return true

  c.hashToBlock.withValue(ancestorHash, ancestorLoc):
    c.hashToBlock.withValue(blockHash, loc):
      var branch = ancestorLoc.branch
      while not branch.isNil:
        if loc.branch == branch:
          return true
        branch = branch.parent

  false

proc isCanonicalAncestor*(c: ForkedChainRef,
                    blockNumber: BlockNumber,
                    blockHash: Hash32): bool =
  if blockNumber >= c.activeBranch.headNumber:
    return false

  if blockHash == c.activeBranch.headHash:
    return false

  if c.baseBranch.tailNumber < c.activeBranch.headNumber:
    # The current canonical chain in memory is headed by
    # activeBranch.header
    var branch = c.activeBranch
    while not branch.isNil:
      if branch.hasHashAndNumber(blockHash, blockNumber):
        return true
      branch = branch.parent

  # canonical chain in database should have a marker
  # and the marker is block number
  let canonHash = c.baseTxFrame.getBlockHash(blockNumber).valueOr:
    return false
  canonHash == blockHash

iterator txHashInRange*(c: ForkedChainRef, fromHash: Hash32, toHash: Hash32): Hash32 =
  ## toHash should be ancestor of fromHash
  ## exclude base from iteration, new block produced by txpool
  ## should not reach base
  let baseHash = c.baseBranch.tailHash
  var prevHash = fromHash
  while prevHash != baseHash:
    c.hashToBlock.withValue(prevHash, loc) do:
      if toHash == prevHash:
        break
      for tx in loc[].transactions:
        let txHash = rlpHash(tx)
        yield txHash
      prevHash = loc[].parentHash
    do:
      break
