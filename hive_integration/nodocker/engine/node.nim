# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../../execution_chain/[
    utils/utils,
    common/common,
    constants,
    db/ledger,
    transaction,
    evm/state,
    evm/types,
    core/dao,
    core/validate,
    core/chain/chain_desc,
    core/executor/calculate_reward,
    core/executor/process_transaction,
    core/executor/process_block
  ],
  chronicles,
  results

{.push raises: [].}

proc processBlock(
    vmState: BaseVMState;  ## Parent environment of header/body block
    blk:     Block;  ## Header/body block to add to the blockchain
    ): Result[void, string] =
  ## Generalised function to processes `(header,body)` pair for any network,
  ## regardless of PoA or not.
  ##
  ## Rather than calculating the PoA state change here, it is done with the
  ## verification in the `chain/persist_blocks.persistBlocks()` method. So
  ## the `poa` descriptor is currently unused and only provided for later
  ## implementations (but can be savely removed, as well.)
  ## variant of `processBlock()` where the `header` argument is explicitely set.
  template header: Header = blk.header

  let com = vmState.com
  if com.daoForkSupport and
     com.daoForkBlock.get == header.number:
    vmState.mutateLedger:
      db.applyDAOHardFork()

  if header.parentBeaconBlockRoot.isSome:
    ? vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.get)

  ? processTransactions(vmState, header, blk.transactions, taskpool = com.taskpool)

  if com.isShanghaiOrLater(header.timestamp):
    for withdrawal in blk.withdrawals.get:
      vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount)

  if header.ommersHash != EMPTY_UNCLE_HASH:
    discard vmState.ledger.txFrame.persistUncles(blk.uncles)

  # EIP-3675: no reward for miner in POA/POS
  if com.proofOfStake(header, vmState.ledger.txFrame):
    vmState.calculateReward(header, blk.uncles)

  vmState.mutateLedger:
    let clearEmptyAccount = com.isSpuriousOrLater(header.number)
    db.persist(clearEmptyAccount)

  ok()

proc getVmState(c: ChainRef, header: Header, txFrame: CoreDbTxRef):
                 Result[BaseVMState, string] =
  let
    parent  = ?txFrame.getBlockHeader(header.parentHash)
    vmState = BaseVMState()
  vmState.init(parent, header, c.com, txFrame, storeSlotHash = false)
  return ok(vmState)

# A stripped down version of persistBlocks without validation
# intended to accepts invalid block
proc setBlock*(c: ChainRef; blk: Block): Result[void, string] =
  template header: Header = blk.header
  let txFrame = c.db.ctx.txFrameBegin(c.db.ctx.baseTxFrame())

  # Needed for figuring out whether KVT cleanup is due (see at the end)
  let
    vmState = ? c.getVmState(header, txFrame)
  ? vmState.processBlock(blk)

  ? txFrame.persistHeaderAndSetHead(header, c.com.startOfHistory)

  txFrame.persistTransactions(header.number, header.txRoot, blk.transactions)
  txFrame.persistReceipts(header.receiptsRoot, vmState.receipts)

  if blk.withdrawals.isSome:
    txFrame.persistWithdrawals(header.withdrawalsRoot.get, blk.withdrawals.get)

  # update currentBlock *after* we persist it
  # so the rpc return consistent result
  # between eth_blockNumber and eth_syncing
  c.com.syncCurrent = header.number

  txFrame.checkpoint(header.number)

  # For the `Aristo` database, this code position is only reached if the
  # the parent state of the first block (as registered in `headers[0]`) was
  # the canonical state before updating. So this state will be saved with
  # `persistent()` together with the respective block number.
  c.db.persist(txFrame)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
