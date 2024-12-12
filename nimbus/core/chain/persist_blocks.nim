# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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
    NoValidation # Validate the batch instead of validating each block in it
    NoFullValidation # Validate the batch instead of validating each block in it
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
    dbTx: CoreDbTxRef
    stats*: PersistStats

    parent: Header
    parentHash: Hash32

  PersistStats* = tuple[blocks: int, txs: int, gas: GasInt]

const NoPersistBodies* = {NoPersistTransactions, NoPersistUncles, NoPersistWithdrawals}

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc getVmState(
    c: ChainRef, parent, header: Header, storeSlotHash = false
): Result[BaseVMState, string] =
  if not c.vmState.isNil:
    if not c.vmState.reinit(parent = parent, header = header, linear = true):
      return err("Could not reinit VMState")
    return ok(c.vmState)

  let vmState = BaseVMState()
  if not vmState.init(header, c.com, storeSlotHash = storeSlotHash):
    return err("Could not initialise VMState")
  ok(vmState)

proc dispose*(p: var Persister) =
  if p.dbTx != nil:
    p.dbTx.dispose()
    p.dbTx = nil

proc init*(T: type Persister, c: ChainRef, flags: PersistBlockFlags): T =
  T(c: c, flags: flags)

proc checkpoint*(p: var Persister): Result[void, string] =
  if p.dbTx != nil:
    p.dbTx.commit()
    p.dbTx = nil

  # Save and record the block number before the last saved block state.
  p.c.db.persistent(p.parent.number).isOkOr:
    return err("Failed to save state: " & $$error)

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
  let skipValidation = true
    # NoFullValidation in p.flags and header.number != toBlock or NoValidation inp.flags

  let vmState =
    ?c.getVmState(p.parent, header, storeSlotHash = NoPersistSlotHashes notin p.flags)

  # TODO even if we're skipping validation, we should perform basic sanity
  #      checks on the block and header - that fields are sanely set for the
  #      given hard fork and similar path-independent checks - these same
  #      sanity checks should be performed early in the processing pipeline no
  #      matter their provenance.
  if not skipValidation and c.extraValidation and c.verifyFrom <= header.number:
    # TODO: how to checkseal from here
    ?c.com.validateHeaderAndKinship(blk, p.parent, checkSealOK = false)

  # Generate receipts for storage or validation but skip them otherwise
  ?vmState.processBlock(
    blk,
    skipValidation,
    skipReceipts = skipValidation and NoPersistReceipts in p.flags,
    skipUncles = NoPersistUncles in p.flags,
    taskpool = c.com.taskpool,
  )

  let blockHash = header.blockHash()
  if NoPersistHeader notin p.flags:
    ?c.db.persistHeader(
      blockHash, header, c.com.proofOfStake(header), c.com.startOfHistory
    )

  if NoPersistTransactions notin p.flags:
    c.db.persistTransactions(header.number, header.txRoot, blk.transactions)

  if NoPersistReceipts notin p.flags:
    c.db.persistReceipts(header.receiptsRoot, vmState.receipts)

  if NoPersistWithdrawals notin p.flags and blk.withdrawals.isSome:
    c.db.persistWithdrawals(
      header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
      blk.withdrawals.get,
    )

  # update currentBlock *after* we persist it
  # so the rpc return consistent result
  # between eth_blockNumber and eth_syncing
  c.com.syncCurrent = header.number

  p.stats.blocks += 1
  p.stats.txs += blk.transactions.len
  p.stats.gas += blk.header.gasUsed

  assign(p.parent, header)
  p.parentHash = blockHash

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

  let res = p.checkpoint()
  p.dispose()
  res and ok(p.stats)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
