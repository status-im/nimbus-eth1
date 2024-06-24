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
  HeadDesc = object
    number: BlockNumber
    hash: Hash256

  BlockDesc = object
    blk: EthBlock
    receipts: seq[Receipt]

  ActiveChain = object
    header: BlockHeader
    hash: Hash256

  ForkedChain* = object
    stagingTx: CoreDbTxRef
    db: CoreDbRef
    com: CommonRef
    blocks: Table[Hash256, BlockDesc]
    headHash: Hash256
    baseHash: Hash256
    baseHeader: BlockHeader
    headHeader: BlockHeader
    heads: seq[HeadDesc]

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

proc updateHeads(c: var ForkedChain,
                 hash: Hash256,
                 header: BlockHeader) =
  for i in 0..<c.heads.len:
    if c.heads[i].hash == header.parentHash:
      c.heads[i] = HeadDesc(
        hash: hash,
        number: header.number,
      )
      return

  c.heads.add HeadDesc(
    hash: hash,
    number: header.number,
  )

proc updateHead(c: var ForkedChain,
                blk: EthBlock,
                receipts: sink seq[Receipt]) =
  template header(): BlockHeader =
    blk.header

  c.headHeader = header
  c.headHash = header.blockHash
  c.blocks[c.headHash] = BlockDesc(
    blk: blk,
    receipts: move(receipts)
  )
  c.updateHeads(c.headHash, header)

proc validatePotentialHead(c: var ForkedChain,
          parent: BlockHeader,
          blk: EthBlock,
          updateHead: bool = true)  =
  let dbTx = c.db.newTransaction()
  defer:
    dbTx.dispose()

  var res = c.processBlock(parent, blk)
  if res.isErr:
    dbTx.rollback()
    return

  dbTx.commit()
  if updateHead:
    c.updateHead(blk, move(res.value))

proc replaySegment(c: var ForkedChain,
                   head: Hash256) =
  var
    prevHash = head
    chain = newSeq[EthBlock]()

  while prevHash != c.baseHash:
    chain.add c.blocks[prevHash].blk
    prevHash = chain[^1].header.parentHash

  c.stagingTx.rollback()
  c.stagingTx = c.db.newTransaction()
  c.headHeader = c.baseHeader
  for i in countdown(chain.high, chain.low):
    c.validatePotentialHead(c.headHeader, chain[i], updateHead = false)
    c.headHeader = chain[i].header

proc writeBaggage(c: var ForkedChain, blockHash: Hash256) =
  var prevHash = blockHash
  while prevHash != c.baseHash:
    let blk =  c.blocks[prevHash]
    c.db.persistTransactions(blk.blk.header.number, blk.blk.transactions)
    c.db.persistReceipts(blk.receipts)
    discard c.db.persistUncles(blk.blk.uncles)
    if blk.blk.withdrawals.isSome:
      c.db.persistWithdrawals(blk.blk.withdrawals.get)
    prevHash = blk.blk.header.parentHash

proc updateBase(c: var ForkedChain,
                newBaseHash: Hash256, newBaseHeader: BlockHeader) =
  # Remove obsolete chains
  for i in 0..<c.heads.len:
    if c.heads[i].number <= c.baseHeader.number:
      var prevHash = c.heads[i].hash
      while prevHash != c.baseHash:
        c.blocks.withValue(prevHash, val) do:
          let rmHash = prevHash
          prevHash = val.blk.header.parentHash
          c.blocks.del(rmHash)
        do:
          # Older chain segment have been deleted
          # by previous head
          break
      c.heads.del(i)

  c.baseHeader = newBaseHeader
  c.baseHash = newBaseHash

func findActiveChain(c: ForkedChain, hash: Hash256): Result[ActiveChain, string] =
  # Find hash belong to which chain
  for x in c.heads:
    let header = c.blocks[x.hash].blk.header
    if x.hash == hash:
      return ok(ActiveChain(header: header, hash: x.hash))

    var prevHash = header.parentHash
    while prevHash != c.baseHash:
      prevHash = c.blocks[prevHash].blk.header.parentHash
      if prevHash == hash:
        return ok(ActiveChain(header: header, hash: x.hash))

  err("Finalized hash is not part of any active chain")

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initForkedChain*(com: CommonRef): ForkedChain =
  result.com = com
  result.db = com.db
<<<<<<< HEAD
  result.stagingTx = com.db.newTransaction()
=======
>>>>>>> 0563e36d (foekr)
  result.baseHeader = com.db.getCanonicalHead()
  let headHash = result.baseHeader.blockHash
  result.headHash = headHash
  result.baseHash = headHash
  result.headHeader = result.baseHeader

proc addBlock*(c: var ForkedChain, blk: EthBlock) =
<<<<<<< HEAD
=======
  if c.stagingTx.isNil:
    c.stagingTx = c.db.newTransaction()

>>>>>>> 0563e36d (foekr)
  template header(): BlockHeader =
    blk.header

  if header.parentHash == c.headHash:
    c.validatePotentialHead(c.headHeader, blk)
    return

  if header.parentHash == c.baseHash:
    c.stagingTx.rollback()
    c.stagingTx = c.db.newTransaction()
    c.validatePotentialHead(c.baseHeader, blk)
    return

  if header.parentHash notin c.blocks:
    # If it's parent is an invalid block
    # there is no hope the descendant is valid
    return

  c.replaySegment(header.parentHash)
  c.validatePotentialHead(c.headHeader, blk)

proc finalizeSegment*(c: var ForkedChain,
        finalizedHash: Hash256): Result[void, string] =
  if finalizedHash == c.baseHash:
    # The base is not updated
    return ok()

  if finalizedHash == c.headHash:
    # Current segment is canonical chain
    c.writeBaggage(finalizedHash)

    # Paranoid check
    doAssert(not c.stagingTx.isNil)
    c.stagingTx.commit()

    # Save and record the block number before the last saved block state.
    c.db.persistent(c.headHeader.number).isOkOr:
      return err("Failed to save state: " & $$error)

    c.stagingTx = c.db.newTransaction()

    c.updateBase(finalizedHash, c.headHeader)
    return ok()

  # If there are multiple heads, find which chain finalizedHash belongs to
  let ac = ?c.findActiveChain(finalizedHash)

  var
    newBaseHash: Hash256
    newBaseHeader: BlockHeader

  c.blocks.withValue(finalizedHash, val) do:
    if ac.header.number <= 128:
      if val.blk.header.number < ac.header.number:
        newBaseHash = finalizedHash
        newBaseHeader = val.blk.header
      else:
        newBaseHash = ac.hash
        newBaseHeader = ac.header
    elif val.blk.header.number < ac.header.number - 128:
      newBaseHash = finalizedHash
      newBaseHeader = val.blk.header
    else:
      newBaseHash = ac.hash
      newBaseHeader = ac.header
  do:
    # Redundant check, already checked in in findActiveChain
    return err("Finalized head not in segments list")

  c.stagingTx.rollback()
  c.stagingTx = c.db.newTransaction()
  c.replaySegment(newBaseHash)
  c.writeBaggage(newBaseHash)

  c.stagingTx.commit()
  c.stagingTx = nil

  c.db.persistent(newBaseHeader.number).isOkOr:
    return err("Failed to save state: " & $$error)

  c.updateBase(newBaseHash, newBaseHeader)

  ok()
