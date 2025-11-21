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

proc writeBaggage*(c: ForkedChainRef,
        blk: Block, blkHash: Hash32,
        txFrame: CoreDbTxRef,
        receipts: openArray[StoredReceipt],
        blockAccessList: Opt[BlockAccessList]) =
  template header(): Header =
    blk.header

  txFrame.persistTransactions(header.number, header.txRoot, blk.transactions)
  txFrame.persistReceipts(header.receiptsRoot, receipts)
  discard txFrame.persistUncles(blk.uncles)
  if blk.withdrawals.isSome:
    txFrame.persistWithdrawals(
      header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
      blk.withdrawals.get)
  if blockAccessList.isSome:
    txFrame.persistBlockAccessList(
      header.blockAccessListHash.expect("blockAccessListHash should be verified before"),
      blk.blockAccessList.get)

proc processBlock*(c: ForkedChainRef,
                  parentBlk: BlockRef,
                  txFrame: CoreDbTxRef,
                  blk: Block,
                  blkHash: Hash32,
                  finalized: bool): Result[seq[StoredReceipt], string] =
  template header(): Header =
    blk.header

  let vmState = BaseVMState()
  vmState.init(
    parentBlk.header,
    header,
    c.com,
    txFrame,
    enableBalTracker = c.com.isAmsterdamOrLater(header.timestamp))

  ?c.com.validateHeaderAndKinship(blk, vmState.parent, txFrame)

  template processBlock(): auto =
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

  c.writeBaggage(blk, blkHash, txFrame, vmState.receipts, vmState.blockAccessList)

  ok(move(vmState.receipts))
