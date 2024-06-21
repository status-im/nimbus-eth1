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
  ForkedChain* = object
    stagingTx: CoreDbTxRef
    db: CoreDbRef
    com: CommonRef
    blocks: Table[Hash256, EthBlock]
    head: Hash256
    base: Hash256
    headBlockNumber: BlockNumber

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc getVmState(c: ForkedChain,
      header: BlockHeader): Result[BaseVMState, string] =
  let vmState = BaseVMState()
  if not vmState.init(header, c.com):
    return err("Could not initialise VMState")
  ok(vmState)

proc processBlock(c: ForkedChain, blk: EthBlock): Result[void, string] =
  template header(): BlockHeader =
    blk.header

  let vmState = ?c.getVmState(header)
  c.com.hardForkTransition(header)

  ?c.com.validateHeaderAndKinship(blk, vmState.parent, checkSealOK = false)

  ?vmState.processBlock(
    blk,
    skipValidation = false,
    skipReceipts = false,
    skipUncles = true,
  )

  let blockHash = header.blockHash()
  if not c.db.persistHeader(
        blockHash,
        header, c.com.consensus == ConsensusType.POS,
        c.com.startOfHistory):
    return err("Could not persist header")

  ok()

proc updateHead(c: var ForkedChain, blk: EthBlock) =
  template header(): BlockHeader =
    blk.header

  c.head = header.blockHash
  c.headBlockNumber = header.number
  c.blocks[c.head] = blk

proc validatePotentialHead(c: var ForkedChain,
          blk: EthBlock,
          updateHead: bool = true): Result[void, string]  =
  let dbTx = c.db.newTransaction()
  defer:
    dbTx.dispose()

  let res = c.processBlock(blk)
  if res.isErr:
    dbTx.rollback()
    return res

  dbTx.commit()
  if updateHead:
    c.updateHead(blk)
  ok()

proc replaySegment(c: var ForkedChain,
                   head: Hash256): BlockNumber =
  var
    prevHash = head
    chain = newSeq[EthBlock]()

  while prevHash != c.base:
    chain.add c.blocks[prevHash]
    prevHash = chain[^1].header.parentHash

  c.stagingTx.rollback()
  c.stagingTx = c.db.newTransaction()
  for i in countdown(chain.high, chain.low):
    c.validatePotentialHead(chain[i], updateHead = false).
      expect("have been validated before")

  chain[^1].header.number

proc updateBase(c: var ForkedChain,
                head: Hash256, headBlockNumber: BlockNumber) =
  c.base = head
  c.head = head
  c.headBlockNumber = headBlockNumber
  c.blocks.clear()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initForkedChain*(com: CommonRef): ForkedChain =
  result.com = com
  result.db = com.db
  result.stagingTx = com.db.newTransaction()
  let head = com.db.getCanonicalHead()
  let headHash = head.blockHash
  result.head = headHash
  result.base = headHash

proc addBlock*(c: var ForkedChain, blk: EthBlock) =
  template header(): BlockHeader =
    blk.header

  if header.parentHash == c.head:
    c.validatePotentialHead(blk).isOkOr:
      # return if it's not a valid block
      return

  if header.parentHash == c.base:
    c.stagingTx.rollback()
    c.stagingTx = c.db.newTransaction()
    c.validatePotentialHead(blk).isOkOr:
      return

  if header.parentHash notin c.blocks:
    # if it's parent is an invalid block
    # there is no hope the descendant is valid
    return

  discard c.replaySegment(header.parentHash)
  c.validatePotentialHead(blk).isOkOr:
    return

proc finalizeSegment*(c: var ForkedChain,
        finalized: Hash256): Result[void, string] =
  if finalized == c.head:
    # the current segment is canonical chain
    c.stagingTx.commit()

    # Save and record the block number before the last saved block state.
    c.db.persistent(c.headBlockNumber).isOkOr:
      return err("Failed to save state: " & $$error)

    c.updateBase(finalized, c.headBlockNumber)
    c.stagingTx = c.db.newTransaction()
    return ok()

  if finalized notin c.blocks:
    return err("Finalized head not in segments list")

  c.stagingTx.rollback()
  c.stagingTx = c.db.newTransaction()
  let headBlockNumber = c.replaySegment(finalized)

  c.stagingTx.commit()
  c.db.persistent(headBlockNumber).isOkOr:
    return err("Failed to save state: " & $$error)

  c.updateBase(finalized, headBlockNumber)
  c.stagingTx = c.db.newTransaction()

  ok()
