# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  ./chain_desc,
  ../../validate,
  ../../executor/process_block,
  ../../../common,
  ../../../db/core_db,
  ../../../evm/types,
  ../../../evm/state,
  ../../../stateless/[witness_generation, witness_verification, stateless_execution],
  ./chain_branch,
  ./chain_db

proc writeBaggage(
    c: ForkedChainRef,
    blockHash: Hash32,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef],
    txFrame: CoreDbTxRef,
    receipts: openArray[StoredReceipt],
    generatedBal: Opt[BlockAccessListRef],
): seq[Hash32] =
  template header(): Header =
    blk.header

  var txHashes = txFrame.persistTransactions(
    header.number, header.txRoot, blk.transactions, txHashToBlock = false)
  txFrame.persistReceipts(header.receiptsRoot, receipts)
  if blk.uncles.len > 0:
    txFrame.persistUncles(blk.header.ommersHash, blk.uncles)

  if blk.withdrawals.isSome:
    txFrame.persistWithdrawals(
      header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
      blk.withdrawals.get,
    )

  if blockAccessList.isSome:
    txFrame.persistBlockAccessList(
      blockHash,
      blockAccessList.get(),
    )
  elif generatedBal.isSome:
    txFrame.persistBlockAccessList(
      blockHash,
      generatedBal.get(),
    )

  move(txHashes)

proc getVmState(
    c: ForkedChainRef,
    parentBlk: BlockRef,
    txFrame: CoreDbTxRef,
    header: Header,
    blockAccessList: Opt[BlockAccessListRef],
    finalized: bool,
): BaseVMState =
  let enableBalTracker = (not finalized or blockAccessList.isNone()) and
      c.com.isAmsterdamOrLater(header.timestamp)

  # The vmState stays nil unless this block succeeds, so a half-executed ledger
  # can never be reused.
  let
    cached = c.vmState
    cachedBlockHash = c.vmStateBlockHash
  c.vmState = nil
  c.vmStateBlockHash.reset()

  # The ledger caches are valid only if the new block builds directly on the
  # block this vmState just executed.
  if not cached.isNil():
    if parentBlk.hash == cachedBlockHash and
        cached.reinit(parentBlk.header, header, txFrame, enableBalTracker):
      return cached

    cached.dispose()


  let vmState = BaseVMState()
  vmState.init(
    parentBlk.header,
    header,
    c.com,
    txFrame,
    enableBalTracker = enableBalTracker,
  )
  vmState

proc processAndPersist*(
    c: ForkedChainRef,
    parentBlk: BlockRef,
    txFrame: CoreDbTxRef,
    blockHash: Hash32,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef],
    finalized: bool,
): Result[seq[Hash32], string] =
  template header(): Header =
    blk.header

  let vmState = c.getVmState(parentBlk, txFrame, header, blockAccessList, finalized)

  var cached = false
  defer:
    if not cached:
      vmState.dispose()

  var flags = {skipUncles}
  if finalized and not c.eagerStateRoot:
    flags.incl {skipStateRootCheck}
  if not vmState.balTrackerEnabled:
    flags.incl {skipPostExecBalCheck}

  template processBlock(): auto =
    # When processing a finalized block, we optimistically assume that the state
    # root will check out and delay such validation for when it's time to persist
    # changes to disk.
    # Finalized blocks are known to be canonical and therefore the bal hash
    # in the header is known to be valid and so it should be good enough to
    # simply check that the provide block BAL (when skipPreExecBalCheck = false)
    # matches the header bal hash. In this case the post execution check can be
    # skipped.
    vmState.processBlock(blk, blockAccessList, flags).isOkOr:
      c.badBlocks.put(blockHash, (blk, vmState.blockAccessList))
      return err(error)

  if not vmState.com.statelessProvider:
    processBlock()
  else:
    # Clear the caches before executing the block to ensure we collect the correct
    # witness keys and block hashes when processing the block as these will be used
    # when building the witness.
    vmState.ledger.clearWitnessKeys()
    vmState.ledger.clearCollapsedSiblings()
    vmState.ledger.clearWrittenCode()
    vmState.ledger.clearBlockHashesCache()

    processBlock()

    let
      preStateLedger = LedgerRef.init(txFrame.parent())
      witness = Witness.build(preStateLedger, vmState.ledger, parentBlk.header, header)

    # Convert the witness to ExecutionWitness format and verify against the pre-stateroot.
    if vmState.com.statelessWitnessValidation:
      doAssert witness.validateKeys(vmState.ledger.getWitnessKeys()).isOk()
      let executionWitness = ExecutionWitnessWithKeys.build(witness, vmState.ledger)
      ?executionWitness.toExecutionWitness().statelessProcessBlock(c.com, blk)

    ?txFrame.persistWitness(blockHash, witness)

  ?vmState.ledger.storeHeldCode()

  # We still need to write header to database
  # because validateUncles still need it
  txFrame.writeBlockOwnershipData(header, blockHash)
  # Lookups by number and by tx hash on disk cover the persisted chain only,
  # they are written when the block becomes base (`writeCanonicalMappings`)
  ?txFrame.persistHeader(blockHash, header, c.com.startOfHistory,
    numberToHash = false)

  var txHashes = c.writeBaggage(
    blockHash, blk, blockAccessList, txFrame, vmState.receipts, vmState.blockAccessList
  )

  vmState.receipts.setLen(0)
  vmState.receiptBlooms.setLen(0)
  vmState.depositReqs.setLen(0)

  # Cache for the next block - the ledger caches stay warm on linear import
  c.vmState = vmState
  c.vmStateBlockHash = blockHash
  cached = true

  ok(move(txHashes))
