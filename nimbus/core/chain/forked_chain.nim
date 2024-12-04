# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
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
  std/tables,
  ../../common,
  ../../db/core_db,
  ../../evm/types,
  ../../evm/state,
  ../validate,
  ../executor/process_block,
  ./forked_chain/chain_desc

export
  BlockDesc,
  ForkedChainRef,
  common,
  core_db

const
  BaseDistance = 128

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template shouldNotKeyError(info: string, body: untyped) =
  try:
    body
  except KeyError as exc:
    raiseAssert info & ": name=" & $exc.name & " msg=" & exc.msg

proc deleteLineage(c: ForkedChainRef; top: Hash32) =
  ## Starting at argument `top`, delete all entries from `c.blocks[]` along
  ## the ancestor chain.
  ##
  var parent = top
  while true:
    c.blocks.withValue(parent, val):
      let w = parent
      parent = val.blk.header.parentHash
      c.blocks.del(w)
      continue
    break

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc processBlock(c: ForkedChainRef,
                  parent: Header,
                  blk: Block): Result[seq[Receipt], string] =
  template header(): Header =
    blk.header

  let vmState = BaseVMState()
  vmState.init(parent, header, c.com)

  if c.extraValidation:
    ?c.com.validateHeaderAndKinship(blk, vmState.parent, checkSealOK = false)

  ?vmState.processBlock(
    blk,
    skipValidation = false,
    skipReceipts = false,
    skipUncles = true,
  )

  # We still need to write header to database
  # because validateUncles still need it
  let blockHash = header.blockHash()
  ?c.db.persistHeader(
     blockHash,
     header,
     c.com.startOfHistory)

  # update currentBlock *after* we persist it
  # so the rpc return consistent result
  # between eth_blockNumber and eth_syncing
  c.com.syncCurrent = header.number

  ok(move(vmState.receipts))

func updateCursorHeads(c: ForkedChainRef,
          cursorHash: Hash32,
          header: Header) =
  # Example of cursorHeads and cursor
  #
  #     -- A1 - A2 - A3    -- D5 - D6
  #    /                  /
  # base - B1 - B2 - B3 - B4
  #             \
  #              --- C3 - C4
  #
  # A3, B4, C4, and D6, are in cursorHeads
  # Any one of them with blockHash == cursorHash
  # is the active chain with cursor pointing to the
  # latest block of that chain.

  for i in 0..<c.cursorHeads.len:
    if c.cursorHeads[i].hash == header.parentHash:
      c.cursorHeads[i].hash = cursorHash
      return

  c.cursorHeads.add CursorDesc(
    hash: cursorHash,
    forkJunction: header.number,
  )

func updateCursor(c: ForkedChainRef,
                  blk: Block,
                  receipts: sink seq[Receipt]) =
  template header(): Header =
    blk.header

  c.cursorHeader = header
  c.cursorHash = header.blockHash

  c.blocks.withValue(c.cursorHash, val):
    # Block exists alrady, so update only
    val.receipts = receipts
  do:
    # New block => update head
    c.blocks[c.cursorHash] = BlockDesc(
      blk: blk,
      receipts: move(receipts))
    c.updateCursorHeads(c.cursorHash, header)

proc validateBlock(c: ForkedChainRef,
          parent: Header,
          blk: Block,
          updateCursor: bool = true): Result[void, string] =
  let dbTx = c.db.ctx.newTransaction()
  defer:
    dbTx.dispose()

  var res = c.processBlock(parent, blk)
  if res.isErr:
    dbTx.rollback()
    return err(res.error)

  dbTx.commit()
  if updateCursor:
    c.updateCursor(blk, move(res.value))

  for i, tx in blk.transactions:
    c.txRecords[rlpHash(tx)] = (blk.header.blockHash, uint64(i))

  ok()

proc replaySegment*(c: ForkedChainRef, target: Hash32) =
  # Replay from base+1 to target block
  var
    prevHash = target
    chain = newSeq[Block]()

  shouldNotKeyError "replaySegment(target)":
    while prevHash != c.baseHash:
      chain.add c.blocks[prevHash].blk
      prevHash = chain[^1].header.parentHash

  c.stagingTx.rollback()
  c.stagingTx = c.db.ctx.newTransaction()
  c.cursorHeader = c.baseHeader
  for i in countdown(chain.high, chain.low):
    c.validateBlock(c.cursorHeader, chain[i],
      updateCursor = false).expect("have been validated before")
    c.cursorHeader = chain[i].header
  c.cursorHash = target

proc replaySegment(c: ForkedChainRef,
                   target: Hash32,
                   parent: Header,
                   parentHash: Hash32) =
  # Replay from parent+1 to target block
  # with assumption last state is at parent
  var
    prevHash = target
    chain = newSeq[Block]()

  shouldNotKeyError "replaySegment(target,parent)":
    while prevHash != parentHash:
      chain.add c.blocks[prevHash].blk
      prevHash = chain[^1].header.parentHash

  c.cursorHeader = parent
  for i in countdown(chain.high, chain.low):
    c.validateBlock(c.cursorHeader, chain[i],
      updateCursor = false).expect("have been validated before")
    c.cursorHeader = chain[i].header
  c.cursorHash = target

proc writeBaggage(c: ForkedChainRef, target: Hash32) =
  # Write baggage from base+1 to target block
  template header(): Header =
    blk.blk.header

  shouldNotKeyError "writeBaggage":
    var prevHash = target
    var count = 0'u64
    while prevHash != c.baseHash:
      let blk =  c.blocks[prevHash]
      c.db.persistTransactions(header.number, header.txRoot, blk.blk.transactions)
      c.db.persistReceipts(header.receiptsRoot, blk.receipts)
      discard c.db.persistUncles(blk.blk.uncles)
      if blk.blk.withdrawals.isSome:
        c.db.persistWithdrawals(
          header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
          blk.blk.withdrawals.get)
      for tx in blk.blk.transactions:
        c.txRecords.del(rlpHash(tx))
      prevHash = header.parentHash
      count.inc

    notice "Finalized blocks persisted",
      numberOfBlocks = count,
      last = target.short,
      baseNumber = c.baseHeader.number,
      baseHash = c.baseHash.short

func updateBase(c: ForkedChainRef, pvarc: PivotArc) =
  ## Remove obsolete chains, example:
  ##
  ##     A1 - A2 - A3          D5 - D6
  ##    /                     /
  ## base - B1 - B2 - [B3] - B4 - B5
  ##         \          \
  ##          C2 - C3    E4 - E5
  ##
  ## where `B1..B5` is the `pvarc.cursor` arc and `[B5]` is the `pvarc.pv`.
  #
  ## The `base` will be moved to position `[B3]`. Both chains `A` and `C`
  ## will be removed but not so for `D` and `E`, and `pivot` arc `B` will
  ## be curtailed below `B4`.
  ##
  var newCursorHeads: seq[CursorDesc]       # Will become new `c.cursorHeads`
  for ch in c.cursorHeads:
    if pvarc.pvNumber < ch.forkJunction:
      # On the example, this would be any of chain `D` or `E`.
      newCursorHeads.add ch

    elif ch.hash == pvarc.cursor.hash:
      # On the example, this would be chain `B`.
      newCursorHeads.add CursorDesc(
        hash:         ch.hash,
        forkJunction: pvarc.pvNumber + 1)

    else:
      # On the example, this would be either chain `A` or `B`.
      c.deleteLineage ch.hash

  # Cleanup in-memory blocks starting from newBase backward
  # while blocks from newBase+1 to canonicalCursor not deleted
  # e.g. B4 onward
  c.deleteLineage pvarc.pvHash

  # Implied deletion of chain heads (if any)
  c.cursorHeads.swap newCursorHeads

  c.baseHeader = pvarc.pvHeader
  c.baseHash = pvarc.pvHash

func findCursorArc(c: ForkedChainRef, hash: Hash32): Result[PivotArc, string] =
  ## Find the `cursor` arc that contains the block relative to the
  ## argument `hash`.
  ##
  if hash == c.baseHash:
    # The cursorHash here should not be used for next step
    # because it not point to any active chain
    return ok PivotArc(
      pvHash:         c.baseHash,
      pvHeader:       c.baseHeader,
      cursor: CursorDesc(
        forkJunction: c.baseHeader.number,
        hash:         c.baseHash))

  for ch in c.cursorHeads:
    var top = ch.hash
    while true:
      c.blocks.withValue(top, val):
        if ch.forkJunction <= val.blk.header.number:
          if top == hash:
            return ok PivotArc(
              pvHash:   hash,
              pvHeader: val.blk.header,
              cursor:   ch)
          if ch.forkJunction < val.blk.header.number:
            top = val.blk.header.parentHash
            continue
      break

  err("Block hash is not part of any active chain")

func findHeader(
    c: ForkedChainRef;
    itHash: Hash32;
    headHash: Hash32;
      ): Result[Header, string] =
  ## Find header for argument `itHash` on argument `headHash` ancestor chain.
  ##
  if itHash == c.baseHash:
    return ok(c.baseHeader)

  # Find `pvHash` on the ancestor lineage of `headHash`
  var prevHash = headHash
  while true:
    c.blocks.withValue(prevHash, val):
      if prevHash == itHash:
        return ok(val.blk.header)
      prevHash = val.blk.header.parentHash
      continue
    break

  err("Block not in argument head ancestor lineage")

func calculateNewBase(
    c: ForkedChainRef;
    finalized: BlockNumber;
    pvarc: PivotArc;
      ): PivotArc =
  ## It is required that the `finalized` argument is on the `pvarc` arc, i.e.
  ## it ranges beween `pvarc.cursor.forkJunction` and
  ## `c.blocks[pvarc.cursor.head].number`.
  ##
  ## The function returns a cursor arc containing a new base position. It is
  ## calculated as follows.
  ##
  ## Starting at the argument `pvarc.pvHead` searching backwards, the new base
  ## is the position of the block with number `finalized`.
  ##
  ## Before searching backwards, the `finalized` argument might be adjusted
  ## and made smaller so that a minimum distance to the head on the cursor arc
  ## applies.
  ##
  # It's important to have base at least `baseDistance` behind head
  # so we can answer state queries about history that deep.
  let target = min(finalized,
    max(pvarc.pvNumber, c.baseDistance) - c.baseDistance)

  # Can only increase base block number.
  if target <= c.baseHeader.number:
    return PivotArc(
      pvHash:         c.baseHash,
      pvHeader:       c.baseHeader,
      cursor: CursorDesc(
        forkJunction: c.baseHeader.number,
        hash:         c.baseHash))

  var prevHash = pvarc.pvHash
  while true:
    c.blocks.withValue(prevHash, val):
      if target == val.blk.header.number:
        if pvarc.cursor.forkJunction <= target:
          # OK, new base stays on the argument pivot arc.
          # ::
          #                 B1 - B2 - B3 - B4
          #                /      ^    ^    ^
          #   base - A1 - A2 - A3 |    |    |
          #                       |    pv   CCH
          #                       |
          #                       target
          #
          return PivotArc(
            pvHash:   prevHash,
            pvHeader: val.blk.header,
            cursor:   pvarc.cursor)
        else:
          # The new base (aka target) falls out of the argument pivot branch,
          # ending up somewhere on a parent branch.
          # ::
          #                 B1 - B2 - B3 - B4
          #                /           ^    ^
          #   base - A1 - A2 - A3      |    |
          #           ^                pv   CCH
          #           |
          #           target
          #
          return c.findCursorArc(prevHash).expect "valid cursor arc"
      prevHash = val.blk.header.parentHash
      continue
    break

  doAssert(false, "Unreachable code, finalized block outside cursor arc")

func trimCursorArc(c: ForkedChainRef, pvarc: PivotArc) =
  ## Curb argument `pvarc.cursor` head so that it ends up at `pvarc.pv`.
  ##
  # Maybe the current active chain is longer than canonical chain
  shouldNotKeyError "trimCanonicalChain":
    var prevHash = pvarc.cursor.hash
    while prevHash != c.baseHash:
      let header = c.blocks[prevHash].blk.header
      if header.number > pvarc.pvNumber:
        c.blocks.del(prevHash)
      else:
        break
      prevHash = header.parentHash

  if c.cursorHeads.len == 0:
    return

  # Update cursorHeads if indeed we trim
  for i in 0..<c.cursorHeads.len:
    if c.cursorHeads[i].hash == pvarc.cursor.hash:
      c.cursorHeads[i].hash = pvarc.pvHash
      return

  doAssert(false, "Unreachable code")

proc setHead(c: ForkedChainRef, pvarc: PivotArc) =
  # TODO: db.setHead should not read from db anymore
  # all canonical chain marking
  # should be done from here.
  discard c.db.setHead(pvarc.pvHash)

  # update global syncHighest
  c.com.syncHighest = pvarc.pvNumber

proc updateHeadIfNecessary(c: ForkedChainRef, pvarc: PivotArc) =
  # update head if the new head is different
  # from current head or current chain
  if c.cursorHash != pvarc.cursor.hash:
    if not c.stagingTx.isNil:
      c.stagingTx.rollback()
    c.stagingTx = c.db.ctx.newTransaction()
    c.replaySegment(pvarc.pvHash)

  c.trimCursorArc(pvarc)
  if c.cursorHash != pvarc.pvHash:
    c.cursorHeader = pvarc.pvHeader
    c.cursorHash = pvarc.pvHash

  if c.stagingTx.isNil:
    # setHead below don't go straight to db
    c.stagingTx = c.db.ctx.newTransaction()

  c.setHead(pvarc)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type ForkedChainRef;
    com: CommonRef;
    baseDistance = BaseDistance.uint64;
    extraValidation = true;
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
    base = com.db.getSavedStateBlockNumber
    baseHash = com.db.getBlockHash(base).expect("baseHash exists")
    baseHeader = com.db.getBlockHeader(baseHash).expect("base header exists")

  # update global syncStart
  com.syncStart = baseHeader.number

  T(com:             com,
    db:              com.db,
    baseHeader:      baseHeader,
    cursorHash:      baseHash,
    baseHash:        baseHash,
    cursorHeader:    baseHeader,
    extraValidation: extraValidation,
    baseDistance:    baseDistance)

proc newForkedChain*(com: CommonRef,
                     baseHeader: Header,
                     baseDistance: uint64 = BaseDistance,
                     extraValidation: bool = true): ForkedChainRef =
  ## This constructor allows to set up the base state which might be needed
  ## for some particular test or other applications. Otherwise consider
  ## `init()`.
  let baseHash = baseHeader.blockHash
  let chain = ForkedChainRef(
    com: com,
    db : com.db,
    baseHeader  : baseHeader,
    cursorHash  : baseHash,
    baseHash    : baseHash,
    cursorHeader: baseHeader,
    extraValidation: extraValidation,
    baseDistance: baseDistance)

  # update global syncStart
  com.syncStart = baseHeader.number
  chain

proc importBlock*(c: ForkedChainRef, blk: Block): Result[void, string] =
  # Try to import block to canonical or side chain.
  # return error if the block is invalid
  if c.stagingTx.isNil:
    c.stagingTx = c.db.ctx.newTransaction()

  template header(): Header =
    blk.header

  if header.parentHash == c.cursorHash:
    return c.validateBlock(c.cursorHeader, blk)

  if header.parentHash == c.baseHash:
    c.stagingTx.rollback()
    c.stagingTx = c.db.ctx.newTransaction()
    return c.validateBlock(c.baseHeader, blk)

  if header.parentHash notin c.blocks:
    # If it's parent is an invalid block
    # there is no hope the descendant is valid
    debug "Parent block not found",
      blockHash = header.blockHash.short,
      parentHash = header.parentHash.short
    return err("Block is not part of valid chain")

  # TODO: If engine API keep importing blocks
  # but not finalized it, e.g. current chain length > StagedBlocksThreshold
  # We need to persist some of the in-memory stuff
  # to a "staging area" or disk-backed memory but it must not afect `base`.
  # `base` is the point of no return, we only update it on finality.

  c.replaySegment(header.parentHash)
  c.validateBlock(c.cursorHeader, blk)

proc forkChoice*(c: ForkedChainRef,
                 headHash: Hash32,
                 finalizedHash: Hash32): Result[void, string] =
  if headHash == c.cursorHash and finalizedHash == static(default(Hash32)):
    # Do nothing if the new head already our current head
    # and there is no request to new finality
    return ok()

  # Find the unique cursor arc where `headHash` is a member of.
  let pvarc = ?c.findCursorArc(headHash)

  if finalizedHash == static(default(Hash32)):
    # skip newBase calculation and skip chain finalization
    # if finalizedHash is zero
    c.updateHeadIfNecessary(pvarc)
    return ok()

  # Finalized block must be parent or on the new canonical chain which is
  # represented by `pvarc`.
  let finalizedHeader = ?c.findHeader(finalizedHash, pvarc.pvHash)

  let newBase = c.calculateNewBase(finalizedHeader.number, pvarc)

  if newBase.pvHash == c.baseHash:
    # The base is not updated but the cursor maybe need update
    c.updateHeadIfNecessary(pvarc)
    return ok()

  # At this point cursorHeader.number > baseHeader.number
  if newBase.pvHash == c.cursorHash:
    # Paranoid check, guaranteed by `newBase.hash == c.cursorHash`
    doAssert(not c.stagingTx.isNil)

    # CL decide to move backward and then forward?
    if c.cursorHeader.number < pvarc.pvNumber:
      c.replaySegment(pvarc.pvHash, c.cursorHeader, c.cursorHash)

    # Current segment is canonical chain
    c.writeBaggage(newBase.pvHash)
    c.setHead(pvarc)

    c.stagingTx.commit()
    c.stagingTx = nil

    # Move base to newBase
    c.updateBase(newBase)

    # Save and record the block number before the last saved block state.
    c.db.persistent(newBase.pvNumber).isOkOr:
      return err("Failed to save state: " & $$error)

    return ok()

  # At this point finalizedHeader.number is <= headHeader.number
  # and possibly switched to other chain beside the one with cursor
  doAssert(finalizedHeader.number <= pvarc.pvNumber)
  doAssert(newBase.pvNumber <= finalizedHeader.number)

  # Write segment from base+1 to newBase into database
  c.stagingTx.rollback()
  c.stagingTx = c.db.ctx.newTransaction()

  if newBase.pvNumber > c.baseHeader.number:
    c.replaySegment(newBase.pvHash)
    c.writeBaggage(newBase.pvHash)
    c.stagingTx.commit()
    c.stagingTx = nil
    # Update base forward to newBase
    c.updateBase(newBase)
    c.db.persistent(newBase.pvNumber).isOkOr:
      return err("Failed to save state: " & $$error)

  if c.stagingTx.isNil:
    # replaySegment or setHead below don't
    # go straight to db
    c.stagingTx = c.db.ctx.newTransaction()

  # Move chain state forward to current head
  if newBase.pvNumber < pvarc.pvNumber:
    c.replaySegment(pvarc.pvHash)

  c.setHead(pvarc)

  # Move cursor to current head
  c.trimCursorArc(pvarc)
  if c.cursorHash != pvarc.pvHash:
    c.cursorHeader = pvarc.pvHeader
    c.cursorHash = pvarc.pvHash

  ok()

func haveBlockAndState*(c: ForkedChainRef, blockHash: Hash32): bool =
  if c.blocks.hasKey(blockHash):
    return true
  if c.baseHash == blockHash:
    return true
  false

proc haveBlockLocally*(c: ForkedChainRef, blockHash: Hash32): bool =
  if c.blocks.hasKey(blockHash):
    return true
  if c.baseHash == blockHash:
    return true
  c.db.headerExists(blockHash)

func stateReady*(c: ForkedChainRef, header: Header): bool =
  let blockHash = header.blockHash
  blockHash == c.cursorHash

func com*(c: ForkedChainRef): CommonRef =
  c.com

func db*(c: ForkedChainRef): CoreDbRef =
  c.db

func latestHeader*(c: ForkedChainRef): Header =
  c.cursorHeader

func latestNumber*(c: ForkedChainRef): BlockNumber =
  c.cursorHeader.number

func latestHash*(c: ForkedChainRef): Hash32 =
  c.cursorHash

func baseNumber*(c: ForkedChainRef): BlockNumber =
  c.baseHeader.number

func baseHash*(c: ForkedChainRef): Hash32 =
  c.baseHash

func txRecords*(c: ForkedChainRef, txHash: Hash32): (Hash32, uint64) =
  c.txRecords.getOrDefault(txHash, (Hash32.default, 0'u64))

func isInMemory*(c: ForkedChainRef, blockHash: Hash32): bool =
  c.blocks.hasKey(blockHash)

func memoryBlock*(c: ForkedChainRef, blockHash: Hash32): BlockDesc =
  c.blocks.getOrDefault(blockHash)

func memoryTransaction*(c: ForkedChainRef, txHash: Hash32): Opt[Transaction] =
  let (blockHash, index) = c.txRecords.getOrDefault(txHash, (Hash32.default, 0'u64))
  c.blocks.withValue(blockHash, val) do:
    return Opt.some(val.blk.transactions[index])
  return Opt.none(Transaction)

proc latestBlock*(c: ForkedChainRef): Block =
  c.blocks.withValue(c.cursorHash, val) do:
    return val.blk
  c.db.getEthBlock(c.cursorHash).expect("cursorBlock exists")

proc headerByNumber*(c: ForkedChainRef, number: BlockNumber): Result[Header, string] =
  if number > c.cursorHeader.number:
    return err("Requested block number not exists: " & $number)

  if number == c.cursorHeader.number:
    return ok(c.cursorHeader)

  if number == c.baseHeader.number:
    return ok(c.baseHeader)

  if number < c.baseHeader.number:
    return c.db.getBlockHeader(number)

  shouldNotKeyError "headerByNumber":
    var prevHash = c.cursorHeader.parentHash
    while prevHash != c.baseHash:
      let header = c.blocks[prevHash].blk.header
      if header.number == number:
        return ok(header)
      prevHash = header.parentHash

  doAssert(false, "headerByNumber: Unreachable code")

proc headerByHash*(c: ForkedChainRef, blockHash: Hash32): Result[Header, string] =
  c.blocks.withValue(blockHash, val) do:
    return ok(val.blk.header)
  do:
    if c.baseHash == blockHash:
      return ok(c.baseHeader)
    return c.db.getBlockHeader(blockHash)

proc blockByHash*(c: ForkedChainRef, blockHash: Hash32): Result[Block, string] =
  # used by getPayloadBodiesByHash
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/shanghai.md#specification-3
  # 4. Client software MAY NOT respond to requests for finalized blocks by hash.
  c.blocks.withValue(blockHash, val) do:
    return ok(val.blk)
  do:
    return c.db.getEthBlock(blockHash)

proc blockByNumber*(c: ForkedChainRef, number: BlockNumber): Result[Block, string] =
  if number > c.cursorHeader.number:
    return err("Requested block number not exists: " & $number)

  if number < c.baseHeader.number:
    return c.db.getEthBlock(number)

  shouldNotKeyError "blockByNumber":
    var prevHash = c.cursorHash
    while prevHash != c.baseHash:
      c.blocks.withValue(prevHash, item):
        if item.blk.header.number == number:
          return ok(item.blk)
        prevHash = item.blk.header.parentHash
  return err("Block not found, number = " & $number)

func blockFromBaseTo*(c: ForkedChainRef, number: BlockNumber): seq[Block] =
  # return block in reverse order
  shouldNotKeyError "blockFromBaseTo":
    var prevHash = c.cursorHash
    while prevHash != c.baseHash:
      c.blocks.withValue(prevHash, item):
        if item.blk.header.number <= number:
          result.add item.blk
        prevHash = item.blk.header.parentHash

func isCanonical*(c: ForkedChainRef, blockHash: Hash32): bool =
  if blockHash == c.baseHash:
    return true

  shouldNotKeyError "isCanonical":
    var prevHash = c.cursorHash
    while prevHash != c.baseHash:
      c.blocks.withValue(prevHash, item):
        if blockHash == prevHash:
          return true
        prevHash = item.blk.header.parentHash

proc isCanonicalAncestor*(c: ForkedChainRef,
                    blockNumber: BlockNumber,
                    blockHash: Hash32): bool =
  if blockNumber >= c.cursorHeader.number:
    return false

  if blockHash == c.cursorHash:
    return false

  if c.baseHeader.number < c.cursorHeader.number:
    # The current canonical chain in memory is headed by
    # cursorHeader
    shouldNotKeyError "isCanonicalAncestor":
      var prevHash = c.cursorHeader.parentHash
      while prevHash != c.baseHash:
        var header = c.blocks[prevHash].blk.header
        if prevHash == blockHash and blockNumber == header.number:
          return true
        prevHash = header.parentHash

  # canonical chain in database should have a marker
  # and the marker is block number
  let canonHash = c.db.getBlockHash(blockNumber).valueOr:
    return false
  canonHash == blockHash
