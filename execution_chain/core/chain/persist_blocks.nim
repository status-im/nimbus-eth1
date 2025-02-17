# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  stew/assign2,
  results,
  ../../evm/state,
  ../../evm/types,
  ../executor,
  ../validate,
  ./chain_desc,
  chronicles,
  stint

when not defined(release):
  import
    #../../tracer,
    ../../utils/utils

export results

type
  PersistBlockFlag* = enum
    NoValidation # Disable chunk state root validation
    NoFullValidation # Disable per-block validation
    NoPersistHeader
    NoPersistTransactions
    NoPersistUncles
    NoPersistWithdrawals
    NoPersistReceipts
    NoPersistSlotHashes

  PersistBlockFlags* = set[PersistBlockFlag]

  Persister* = object
    c: ChainRef
    flags: PersistBlockFlags

    vmState: BaseVMState
    stats*: PersistStats

    parent: Header

  PersistStats* = tuple[blocks: int, txs: int, gas: GasInt]

const NoPersistBodies* = {NoPersistTransactions, NoPersistUncles, NoPersistWithdrawals}

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc getVmState(
    p: var Persister, header: Header, storeSlotHash = false
): Result[BaseVMState, string] =
  if p.vmState == nil:
    let
      vmState = BaseVMState()
      txFrame = p.c.db.baseTxFrame.txFrameBegin()
      parent = ?txFrame.getBlockHeader(header.parentHash)

    doAssert txFrame.getSavedStateBlockNumber() == parent.number
    vmState.init(parent, header, p.c.com, txFrame, storeSlotHash = storeSlotHash)
    p.vmState = vmState
  else:
    if header.number != p.parent.number + 1:
      return err("Only linear histories supported by Persister")

    if not p.vmState.reinit(p.parent, header):
      return err("Could not update VMState for new block")

  ok(p.vmState)

proc dispose*(p: var Persister) =
  p.vmState.ledger.txFrame.dispose()
  p.vmState = nil

proc init*(T: type Persister, c: ChainRef, flags: PersistBlockFlags): T =
  T(c: c, flags: flags)

proc checkpoint*(p: var Persister): Result[void, string] =
  if NoValidation notin p.flags:
    let stateRoot = p.vmState.ledger.txFrame.getStateRoot().valueOr:
        return err($$error)

    if p.parent.stateRoot != stateRoot:
      # TODO replace logging with better error
      debug "wrong state root in block",
        blockNumber = p.parent.number,
        blockHash = p.parent.blockHash,
        parentHash = p.parent.parentHash,
        expected = p.parent.stateRoot,
        actual = stateRoot
      return err(
        "stateRoot mismatch, expect: " & $p.parent.stateRoot & ", got: " & $stateRoot
      )

  # Move in-memory state to disk
  p.c.db.persist(p.vmState.ledger.txFrame)
  # Get a new frame since the DB assumes ownership
  p.vmState.ledger.txFrame = p.c.db.baseTxFrame().txFrameBegin()

  ok()

proc persistBlock*(p: var Persister, blk: Block): Result[void, string] =
  template header(): Header =
    blk.header

  let c = p.c

  # Full validation means validating the state root at every block and
  # performing the more expensive hash computations on the block itself, ie
  # verifying that the transaction and receipts roots are valid - when not
  # doing full validation, we skip these expensive checks relying instead
  # on the source of the data to have performed them previously or because
  # the cost of failure is low.
  # TODO Figure out the right balance for header fields - in particular, if
  #      we receive instruction from the CL while syncing that a block is
  #      CL-valid, do we skip validation while "far from head"? probably yes.
  #      This requires performing a header-chain validation from that CL-valid
  #      block which the current code doesn't express.
  #      Also, the potential avenues for corruption should be described with
  #      more rigor, ie if the txroot doesn't match but everything else does,
  #      can the state root of the last block still be correct? Dubious, but
  #      what would be the consequences? We would roll back the full set of
  #      blocks which is fairly low-cost.
  let
    skipValidation = NoValidation in p.flags
    vmState = ?p.getVmState(header, storeSlotHash = NoPersistSlotHashes notin p.flags)
    txFrame = vmState.ledger.txFrame

  # TODO even if we're skipping validation, we should perform basic sanity
  #      checks on the block and header - that fields are sanely set for the
  #      given hard fork and similar path-independent checks - these same
  #      sanity checks should be performed early in the processing pipeline no
  #      matter their provenance.
  if not skipValidation:
    ?c.com.validateHeaderAndKinship(blk, vmState.parent, txFrame)

  # Generate receipts for storage or validation but skip them otherwise
  ?vmState.processBlock(
    blk,
    skipValidation,
    skipReceipts = skipValidation and NoPersistReceipts in p.flags,
    skipUncles = NoPersistUncles in p.flags,
    taskpool = c.com.taskpool,
  )

  if NoPersistHeader notin p.flags:
    let blockHash = header.blockHash()
    ?txFrame.persistHeaderAndSetHead(blockHash, header, c.com.startOfHistory)

  if NoPersistTransactions notin p.flags:
    txFrame.persistTransactions(header.number, header.txRoot, blk.transactions)

  if NoPersistReceipts notin p.flags:
    txFrame.persistReceipts(header.receiptsRoot, vmState.receipts)

  if NoPersistWithdrawals notin p.flags and blk.withdrawals.isSome:
    txFrame.persistWithdrawals(
      header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
      blk.withdrawals.get,
    )

  p.stats.blocks += 1
  p.stats.txs += blk.transactions.len
  p.stats.gas += blk.header.gasUsed

  txFrame.checkpoint(header.number)

  assign(p.parent, header)

  ok()

proc persistBlocks*(
    c: ChainRef, blocks: openArray[Block], flags: PersistBlockFlags = {}
): Result[PersistStats, string] =
  # Run the VM here
  if blocks.len == 0:
    debug "Nothing to do"
    return ok(default(PersistStats)) # TODO not nice to return nil

  var p = Persister.init(c, flags)

  for blk in blocks:
    p.persistBlock(blk).isOkOr:
      p.dispose()
      return err(error)

  # update currentBlock *after* we persist it
  # so the rpc return consistent result
  # between eth_blockNumber and eth_syncing
  c.com.syncCurrent = p.parent.number

  let res = p.checkpoint()
  p.dispose()
  res and ok(p.stats)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
