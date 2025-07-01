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
  ../../../evm/state

proc writeBaggage*(c: ForkedChainRef,
        blk: Block, blkHash: Hash32,
        txFrame: CoreDbTxRef,
        receipts: openArray[StoredReceipt]) =
  template header(): Header =
    blk.header

  txFrame.persistTransactions(header.number, header.txRoot, blk.transactions)
  txFrame.persistReceipts(header.receiptsRoot, receipts)
  discard txFrame.persistUncles(blk.uncles)
  if blk.withdrawals.isSome:
    txFrame.persistWithdrawals(
      header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
      blk.withdrawals.get)

template updateSnapshot*(c: ForkedChainRef,
            blk: Block,
            txFrame: CoreDbTxRef) =
  let pos = c.lastSnapshotPos
  c.lastSnapshotPos = (c.lastSnapshotPos + 1) mod c.lastSnapshots.len
  if not isNil(c.lastSnapshots[pos]):
    # Put a cap on frame memory usage by clearing out the oldest snapshots -
    # this works at the expense of making building on said branches slower.
    # 10 is quite arbitrary.
    c.lastSnapshots[pos].clearSnapshot()
    c.lastSnapshots[pos] = nil

  # Block fully written to txFrame, mark it as such
  # Checkpoint creates a snapshot of ancestor changes in txFrame - it is an
  # expensive operation, specially when creating a new branch (ie when blk
  # is being applied to a block that is currently not a head)
  txFrame.checkpoint(blk.header.number)

  c.lastSnapshots[pos] = txFrame

proc processBlock*(c: ForkedChainRef,
                  parent: Header,
                  txFrame: CoreDbTxRef,
                  blk: Block,
                  blkHash: Hash32,
                  finalized: bool): Result[seq[StoredReceipt], string] =
  template header(): Header =
    blk.header

  let vmState = BaseVMState()
  vmState.init(parent, header, c.com, txFrame)

  ?c.com.validateHeaderAndKinship(blk, vmState.parent, txFrame)

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

  # We still need to write header to database
  # because validateUncles still need it
  ?txFrame.persistHeader(blkHash, header, c.com.startOfHistory)

  ok(move(vmState.receipts))

