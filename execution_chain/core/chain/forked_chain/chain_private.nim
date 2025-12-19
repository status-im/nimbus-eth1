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
  ./chain_desc,
  ../../validate,
  ../../executor/process_block,
  ../../../common,
  ../../../db/core_db,
  ../../../evm/types,
  ../../../evm/state,
  ../../../stateless/[witness_generation, witness_verification, stateless_execution],
  ./chain_branch

proc writeBaggage*(
    c: ForkedChainRef,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef],
    blkHash: Hash32,
    txFrame: CoreDbTxRef,
    receipts: openArray[StoredReceipt],
    generatedBal: Opt[BlockAccessListRef],
) =
  template header(): Header =
    blk.header

  txFrame.persistTransactions(header.number, header.txRoot, blk.transactions)
  txFrame.persistReceipts(header.receiptsRoot, receipts)
  discard txFrame.persistUncles(blk.uncles)

  if blk.withdrawals.isSome:
    txFrame.persistWithdrawals(
      header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
      blk.withdrawals.get,
    )

  if blockAccessList.isSome:
    txFrame.persistBlockAccessList(
      blkHash,
      blockAccessList.get(),
    )
  elif generatedBal.isSome:
    txFrame.persistBlockAccessList(
      blkHash,
      generatedBal.get(),
    )

proc processBlock*(
    c: ForkedChainRef,
    parentBlk: BlockRef,
    txFrame: CoreDbTxRef,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef],
    blkHash: Hash32,
    finalized: bool,
): Result[seq[StoredReceipt], string] =
  template header(): Header =
    blk.header

  let vmState = BaseVMState()
  vmState.init(
    parentBlk.header,
    header,
    c.com,
    txFrame,
    enableBalTracker = (not finalized or blockAccessList.isNone()) and
        c.com.isAmsterdamOrLater(header.timestamp),
  )

  c.com.validateHeaderAndKinship(
    blk,
    blockAccessList,
    # Depending on the BAL retention period of clients, finalized blocks might
    # be received without a BAL. In this case we skip checking the BAL against
    # the header bal hash.
    skipPreExecBalCheck = finalized and blockAccessList.isNone(),
    vmState.parent,
    txFrame
  ).isOkOr:
    c.badBlocks.put(blkHash, (blk, vmState.blockAccessList))
    return err(error)

  template processBlock(): auto =
    vmState.processBlock(
      blk,
      skipValidation = false,
      skipReceipts = false,
      skipUncles = true,
      # When processing a finalized block, we optimistically assume that the state
      # root will check out and delay such validation for when it's time to persist
      # changes to disk
      skipStateRootCheck = finalized and not c.eagerStateRoot,
      # Finalized blocks are known to be canonical and therefore the bal hash
      # in the header is known to be valid and so it should be good enough to
      # simply check that the provide block BAL (when skipPreExecBalCheck = false)
      # matches the header bal hash. In this case the post execution check can be
      # skipped.
      skipPostExecBalCheck = not vmState.balTrackerEnabled
    ).isOkOr:
      c.badBlocks.put(blkHash, (blk, vmState.blockAccessList))
      return err(error)

  if not vmState.com.statelessProviderEnabled:
    processBlock()
  else:
    # Clear the caches before executing the block to ensure we collect the correct
    # witness keys and block hashes when processing the block as these will be used
    # when building the witness.
    vmState.ledger.clearWitnessKeys()
    vmState.ledger.clearBlockHashesCache()

    processBlock()

    let
      preStateLedger = LedgerRef.init(parentBlk.txFrame)
      witness = Witness.build(preStateLedger, vmState.ledger, parentBlk.header, header)

    # Convert the witness to ExecutionWitness format and verify against the pre-stateroot.
    if vmState.com.statelessWitnessValidation:
      doAssert witness.validateKeys(vmState.ledger.getWitnessKeys()).isOk()
      let executionWitness = ExecutionWitness.build(witness, vmState.ledger)
      ?executionWitness.statelessProcessBlock(c.com, blk)

    ?vmState.ledger.txFrame.persistWitness(blkHash, witness)

  # We still need to write header to database
  # because validateUncles still need it
  ?txFrame.persistHeader(blkHash, header, c.com.startOfHistory)

  c.writeBaggage(blk, blockAccessList, blkHash, txFrame, vmState.receipts, vmState.blockAccessList)

  ok(move(vmState.receipts))
