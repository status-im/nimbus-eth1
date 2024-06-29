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
  std/tables,
  ../../common,
  ../../db/core_db,
  ../../evm/types,
  ../../evm/state,
  ../validate,
  ../executor/process_block

type
  CursorDesc = object
    forkJunction: BlockNumber
    hash: Hash256

  BlockDesc = object
    blk: EthBlock
    receipts: seq[Receipt]

  BaseDesc = object
    hash: Hash256
    header: BlockHeader

  CanonicalDesc = object
    cursorHash: Hash256
    header: BlockHeader

  ForkedChainRef* = ref object
    stagingTx: CoreDbTxRef
    db: CoreDbRef
    com: CommonRef
    blocks: Table[Hash256, BlockDesc]
    baseHash: Hash256
    baseHeader: BlockHeader
    cursorHash: Hash256
    cursorHeader: BlockHeader
    cursorHeads: seq[CursorDesc]

const
  BaseDistance = 128

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------
template shouldNotKeyError(body: untyped) =
  try:
    body
  except KeyError as exc:
    raiseAssert exc.msg

proc processBlock(c: ForkedChainRef,
                  parent: BlockHeader,
                  blk: EthBlock): Result[seq[Receipt], string] =
  template header(): BlockHeader =
    blk.header

  let vmState = BaseVMState()
  vmState.init(parent, header, c.com)
  c.com.hardForkTransition(header)

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
  if not c.db.persistHeader(
        blockHash,
        header, c.com.consensus == ConsensusType.POS,
        c.com.startOfHistory):
    return err("Could not persist header")

  ok(move(vmState.receipts))

func updateCursorHeads(c: ForkedChainRef,
          cursorHash: Hash256,
          header: BlockHeader) =
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
                  blk: EthBlock,
                  receipts: sink seq[Receipt]) =
  template header(): BlockHeader =
    blk.header

  c.cursorHeader = header
  c.cursorHash = header.blockHash
  c.blocks[c.cursorHash] = BlockDesc(
    blk: blk,
    receipts: move(receipts)
  )
  c.updateCursorHeads(c.cursorHash, header)

proc validateBlock(c: ForkedChainRef,
          parent: BlockHeader,
          blk: EthBlock,
          updateCursor: bool = true): Result[void, string] =
  let dbTx = c.db.newTransaction()
  defer:
    dbTx.dispose()

  var res = c.processBlock(parent, blk)
  if res.isErr:
    dbTx.rollback()
    return err(res.error)

  dbTx.commit()
  if updateCursor:
    c.updateCursor(blk, move(res.value))

  ok()

proc replaySegment(c: ForkedChainRef, target: Hash256) =
  # Replay from base+1 to target block
  var
    prevHash = target
    chain = newSeq[EthBlock]()

  shouldNotKeyError:
    while prevHash != c.baseHash:
      chain.add c.blocks[prevHash].blk
      prevHash = chain[^1].header.parentHash

  c.stagingTx.rollback()
  c.stagingTx = c.db.newTransaction()
  c.cursorHeader = c.baseHeader
  for i in countdown(chain.high, chain.low):
    c.validateBlock(c.cursorHeader, chain[i],
      updateCursor = false).expect("have been validated before")
    c.cursorHeader = chain[i].header

proc writeBaggage(c: ForkedChainRef, target: Hash256) =
  # Write baggage from base+1 to target block
  template header(): BlockHeader =
    blk.blk.header

  shouldNotKeyError:
    var prevHash = target
    while prevHash != c.baseHash:
      let blk =  c.blocks[prevHash]
      c.db.persistTransactions(header.number, header.txRoot, blk.blk.transactions)
      c.db.persistReceipts(header.receiptsRoot, blk.receipts)
      discard c.db.persistUncles(blk.blk.uncles)
      if blk.blk.withdrawals.isSome:
        c.db.persistWithdrawals(
          header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
          blk.blk.withdrawals.get)
      prevHash = header.parentHash

func updateBase(c: ForkedChainRef,
                newBaseHash: Hash256,
                newBaseHeader: BlockHeader,
                canonicalCursorHash: Hash256) =
  var cursorHeadsLen = c.cursorHeads.len
  # Remove obsolete chains, example:
  #     -- A1 - A2 - A3      -- D5 - D6
  #    /                    /
  # base - B1 - B2 - [B3] - B4
  #             \
  #              --- C3 - C4
  # If base move to B3, both A and C will be removed
  # but not D

  for i in 0..<cursorHeadsLen:
    if c.cursorHeads[i].forkJunction <= newBaseHeader.number and
       c.cursorHeads[i].hash != canonicalCursorHash:
      var prevHash = c.cursorHeads[i].hash
      while prevHash != c.baseHash:
        c.blocks.withValue(prevHash, val) do:
          let rmHash = prevHash
          prevHash = val.blk.header.parentHash
          c.blocks.del(rmHash)
        do:
          # Older chain segment have been deleted
          # by previous head
          break
      c.cursorHeads.del(i)
      # If we use `c.cursorHeads.len` in the for loop,
      # the sequence length will not updated
      dec cursorHeadsLen

  # Cleanup in-memory blocks starting from newBase backward
  # while blocks from newBase+1 to canonicalCursor not deleted
  # e.g. B4 onward
  var prevHash = newBaseHash
  while prevHash != c.baseHash:
    c.blocks.withValue(prevHash, val) do:
      let rmHash = prevHash
      prevHash = val.blk.header.parentHash
      c.blocks.del(rmHash)
    do:
      # Older chain segment have been deleted
      # by previous head
      break

  c.baseHeader = newBaseHeader
  c.baseHash = newBaseHash

func findCanonicalHead(c: ForkedChainRef,
                       hash: Hash256): Result[CanonicalDesc, string] =
  if hash == c.baseHash:
    # The cursorHash here should not be used for next step
    # because it not point to any active chain
    return ok(CanonicalDesc(cursorHash: c.baseHash, header: c.baseHeader))

  shouldNotKeyError:
   # Find hash belong to which chain
   for cursor in c.cursorHeads:
     let header = c.blocks[cursor.hash].blk.header
     var prevHash = cursor.hash
     while prevHash != c.baseHash:
       if prevHash == hash:
         return ok(CanonicalDesc(cursorHash: cursor.hash, header: header))
       prevHash = c.blocks[prevHash].blk.header.parentHash

  err("Block hash is not part of any active chain")

func canonicalChain(c: ForkedChainRef,
                    hash: Hash256,
                    headHash: Hash256): Result[BlockHeader, string] =
  if hash == c.baseHash:
    return ok(c.baseHeader)

  shouldNotKeyError:
    var prevHash = headHash
    while prevHash != c.baseHash:
      var header = c.blocks[prevHash].blk.header
      if prevHash == hash:
        return ok(header)
      prevHash = header.parentHash

  err("Block hash not in canonical chain")

func calculateNewBase(c: ForkedChainRef,
               finalizedHeader: BlockHeader,
               headHash: Hash256,
               headHeader: BlockHeader): BaseDesc =
  # It's important to have base at least `BaseDistance` behind head
  # so we can answer state queries about history that deep.

  let targetNumber = min(finalizedHeader.number,
    max(headHeader.number, BaseDistance) - BaseDistance)

  # The distance is less than `BaseDistance`, don't move the base
  if targetNumber - c.baseHeader.number <= BaseDistance:
    return BaseDesc(hash: c.baseHash, header: c.baseHeader)

  shouldNotKeyError:
    var prevHash = headHash
    while prevHash != c.baseHash:
      var header = c.blocks[prevHash].blk.header
      if header.number == targetNumber:
        return BaseDesc(hash: prevHash, header: move(header))
      prevHash = header.parentHash

  doAssert(false, "Unreachable code")

func trimCanonicalChain(c: ForkedChainRef, head: CanonicalDesc) =
  # Maybe the current active chain is longer than canonical chain
  shouldNotKeyError:
    var prevHash = head.cursorHash
    while prevHash != c.baseHash:
      let header = c.blocks[prevHash].blk.header
      if header.number > head.header.number:
        c.blocks.del(prevHash)
      else:
        break
      prevHash = header.parentHash

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc newForkedChain*(com: CommonRef, baseHeader: BlockHeader): ForkedChainRef =
  new(result)
  result.com = com
  result.db  = com.db
  result.baseHeader   = baseHeader
  result.cursorHash   = baseHeader.blockHash
  result.baseHash     = result.cursorHash
  result.cursorHeader = result.baseHeader

proc importBlock*(c: ForkedChainRef, blk: EthBlock): Result[void, string] =
  # Try to import block to canonical or side chain.
  # return error if the block is invalid
  if c.stagingTx.isNil:
    c.stagingTx = c.db.newTransaction()

  template header(): BlockHeader =
    blk.header

  if header.parentHash == c.cursorHash:
    return c.validateBlock(c.cursorHeader, blk)

  if header.parentHash == c.baseHash:
    c.stagingTx.rollback()
    c.stagingTx = c.db.newTransaction()
    return c.validateBlock(c.baseHeader, blk)

  if header.parentHash notin c.blocks:
    # If it's parent is an invalid block
    # there is no hope the descendant is valid
    return err("Block is not part of valid chain")

  # TODO: If engine API keep importing blocks
  # but not finalized it, e.g. current chain length > StagedBlocksThreshold
  # We need to persist some of the in-memory stuff
  # to a "staging area" or disk-backed memory but it must not afect `base`.
  # `base` is the point of no return, we only update it on finality.

  c.replaySegment(header.parentHash)
  c.validateBlock(c.cursorHeader, blk)

proc forkChoice*(c: ForkedChainRef,
                 headHash: Hash256,
                 finalizedHash: Hash256): Result[void, string] =

  # If there are multiple heads, find which chain headHash belongs to
  let head = ?c.findCanonicalHead(headHash)

  # Finalized block must be part of canonical chain
  let finalizedHeader = ?c.canonicalChain(finalizedHash, headHash)

  let newBase = c.calculateNewBase(
    finalizedHeader, headHash, head.header)

  if newBase.hash == c.baseHash:
    # The base is not updated but the cursor maybe need update
    if c.cursorHash != head.cursorHash:
      if not c.stagingTx.isNil:
        c.stagingTx.rollback()
      c.stagingTx = c.db.newTransaction()
      c.replaySegment(headHash)

    c.trimCanonicalChain(head)
    if c.cursorHash != headHash:
      c.cursorHeader = head.header
      c.cursorHash = headHash
    return ok()

  # At this point cursorHeader.number > baseHeader.number
  if newBase.hash == c.cursorHash:
    # Paranoid check, guaranteed by findCanonicalHead
    doAssert(c.cursorHash == head.cursorHash)

    # Current segment is canonical chain
    c.writeBaggage(newBase.hash)

    # Paranoid check, guaranteed by `newBase.hash == c.cursorHash`
    doAssert(not c.stagingTx.isNil)
    c.stagingTx.commit()
    c.stagingTx = nil

    # Move base to newBase
    c.updateBase(newBase.hash, c.cursorHeader, head.cursorHash)

    # Save and record the block number before the last saved block state.
    c.db.persistent(c.cursorHeader.number).isOkOr:
      return err("Failed to save state: " & $$error)

    return ok()

  # At this point finalizedHeader.number is <= headHeader.number
  # and possibly switched to other chain beside the one with cursor
  doAssert(finalizedHeader.number <= head.header.number)
  doAssert(newBase.header.number <= finalizedHeader.number)

  # Write segment from base+1 to newBase into database
  c.stagingTx.rollback()
  c.stagingTx = c.db.newTransaction()
  if newBase.header.number > c.baseHeader.number:
    c.replaySegment(newBase.hash)
    c.writeBaggage(newBase.hash)
    c.stagingTx.commit()
    c.stagingTx = nil
    # Update base forward to newBase
    c.updateBase(newBase.hash, newBase.header, head.cursorHash)
    c.db.persistent(newBase.header.number).isOkOr:
      return err("Failed to save state: " & $$error)

  # Move chain state forward to current head
  if newBase.header.number < head.header.number:
    if c.stagingTx.isNil:
      c.stagingTx = c.db.newTransaction()
    c.replaySegment(headHash)

  # Move cursor to current head
  c.trimCanonicalChain(head)
  if c.cursorHash != headHash:
    c.cursorHeader = head.header
    c.cursorHash = headHash

  ok()
