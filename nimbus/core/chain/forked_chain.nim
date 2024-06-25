# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

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

  ForkedChain* = object
    stagingTx: CoreDbTxRef
    db: CoreDbRef
    com: CommonRef
    blocks: Table[Hash256, BlockDesc]
    baseHash: Hash256
    baseHeader: BlockHeader
    cursorHash: Hash256
    cursorHeader: BlockHeader
    cursorHeads: seq[CursorDesc]

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc processBlock(c: ForkedChain,
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

func updateCursorHeads(c: var ForkedChain,
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

func updateCursor(c: var ForkedChain,
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

proc validateBlock(c: var ForkedChain,
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

proc replaySegment(c: var ForkedChain, target: Hash256) =
  # Replay from base+1 to target block
  var
    prevHash = target
    chain = newSeq[EthBlock]()

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

proc writeBaggage(c: var ForkedChain, target: Hash256) =
  # Write baggage from base+1 to target block
  var prevHash = target
  while prevHash != c.baseHash:
    let blk =  c.blocks[prevHash]
    c.db.persistTransactions(blk.blk.header.number, blk.blk.transactions)
    c.db.persistReceipts(blk.receipts)
    discard c.db.persistUncles(blk.blk.uncles)
    if blk.blk.withdrawals.isSome:
      c.db.persistWithdrawals(blk.blk.withdrawals.get)
    prevHash = blk.blk.header.parentHash

func updateBase(c: var ForkedChain,
                newBaseHash: Hash256, newBaseHeader: BlockHeader) =
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
    if c.cursorHeads[i].forkJunction <= newBaseHeader.number:
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

  c.baseHeader = newBaseHeader
  c.baseHash = newBaseHash

func findCanonicalHead(c: ForkedChain,
                       hash: Hash256): Result[BlockHeader, string] =
  if hash == c.baseHash:
    return ok(c.baseHeader)

  # Find hash belong to which chain
  for x in c.cursorHeads:
    let header = c.blocks[x.hash].blk.header
    var prevHash = x.hash
    while prevHash != c.baseHash:
      if prevHash == hash:
        return ok(header)
      prevHash = c.blocks[prevHash].blk.header.parentHash

  err("Block hash is not part of any active chain")

func canonicalChain(c: ForkedChain,
                    hash: Hash256,
                    headHash: Hash256): Result[BlockHeader, string] =
  if hash == c.baseHash:
    return ok(c.baseHeader)

  var prevHash = headHash
  while prevHash != c.baseHash:
    var header = c.blocks[prevHash].blk.header
    if prevHash == hash:
      return ok(header)
    prevHash = header.parentHash

  err("Block hash not in canonical chain")

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initForkedChain*(com: CommonRef): ForkedChain =
  result.com = com
  result.db = com.db
  result.baseHeader = com.db.getCanonicalHead()
  let cursorHash = result.baseHeader.blockHash
  result.cursorHash = cursorHash
  result.baseHash = cursorHash
  result.cursorHeader = result.baseHeader

proc importBlock*(c: var ForkedChain, blk: EthBlock): Result[void, string] =
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

proc forkChoice*(c: var ForkedChain,
                 headHash: Hash256,
                 finalizedHash: Hash256): Result[void, string] =

  # If there are multiple heads, find which chain headHash belongs to
  let headHeader = ?c.findCanonicalHead(headHash)

  # Finalized block must be part of canonical chain
  let finalizedHeader = ?c.canonicalChain(finalizedHash, headHash)

  if finalizedHash == c.baseHash:
    # The base is not updated
    return ok()

  if finalizedHash == c.cursorHash:
    # Paranoid check, guaranteed by findCanonicalHead
    doAssert(c.cursorHash == headHash)

    # Current segment is canonical chain
    c.writeBaggage(finalizedHash)

    # Paranoid check, guaranteed by `finalizedHash == c.cursorHash`
    doAssert(not c.stagingTx.isNil)
    c.stagingTx.commit()
    c.stagingTx = nil

    # Move base to finalized
    c.updateBase(finalizedHash, c.cursorHeader)

    # Save and record the block number before the last saved block state.
    c.db.persistent(c.cursorHeader.number).isOkOr:
      return err("Failed to save state: " & $$error)

    return ok()

  # At this point finalizedHeader.number is <= headHeader.number
  # and possibly switched to other chain beside the one with cursor
  doAssert(finalizedHeader.number <= headHeader.number)

  # Write segment from base+1 to finalized into database
  c.stagingTx.rollback()
  c.stagingTx = c.db.newTransaction()
  c.replaySegment(finalizedHash)
  c.writeBaggage(finalizedHash)
  c.stagingTx.commit()
  # Update base forward to finalized
  c.updateBase(finalizedHash, finalizedHeader)
  c.db.persistent(finalizedHeader.number).isOkOr:
    return err("Failed to save state: " & $$error)

  # Move chain state forward to current head
  if finalizedHeader.number < headHeader.number:
    c.stagingTx = c.db.newTransaction()
    c.replaySegment(headHash)

  # Move cursor forward to current head
  c.cursorHeader = headHeader
  c.cursorHash = headHash

  ok()
