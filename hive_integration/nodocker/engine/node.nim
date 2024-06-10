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
  ../../../nimbus/[
    utils/utils,
    common/common,
    constants,
    db/ledger,
    transaction,
    vm_state,
    vm_types,
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
    blk:     EthBlock;  ## Header/body block to add to the blockchain
    ): Result[void, string] =
  ## Generalised function to processes `(header,body)` pair for any network,
  ## regardless of PoA or not.
  ##
  ## Rather than calculating the PoA state change here, it is done with the
  ## verification in the `chain/persist_blocks.persistBlocks()` method. So
  ## the `poa` descriptor is currently unused and only provided for later
  ## implementations (but can be savely removed, as well.)
  ## variant of `processBlock()` where the `header` argument is explicitely set.
  template header: BlockHeader = blk.header
  var dbTx = vmState.com.db.newTransaction()
  defer: dbTx.dispose()

  if vmState.com.daoForkSupport and
     vmState.com.daoForkBlock.get == header.number:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  if header.parentBeaconBlockRoot.isSome:
    ? vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.get)

  ? processTransactions(vmState, header, blk.transactions)

  if vmState.determineFork >= FkShanghai:
    for withdrawal in blk.withdrawals.get:
      vmState.stateDB.addBalance(withdrawal.address, withdrawal.weiAmount)

  if header.ommersHash != EMPTY_UNCLE_HASH:
    discard vmState.com.db.persistUncles(blk.uncles)

  # EIP-3675: no reward for miner in POA/POS
  if vmState.com.consensus == ConsensusType.POW:
    vmState.calculateReward(header, blk.uncles)

  vmState.mutateStateDB:
    let clearEmptyAccount = vmState.determineFork >= FkSpurious
    db.persist(clearEmptyAccount)

  dbTx.commit()

  ok()

proc getVmState(c: ChainRef, header: BlockHeader):
                 Result[BaseVMState, void] =
  if c.vmState.isNil.not:
    return ok(c.vmState)

  let vmState = BaseVMState()
  if not vmState.init(header, c.com):
    debug "Cannot initialise VmState",
      number = header.number
    return err()

  return ok(vmState)

# A stripped down version of persistBlocks without validation
# intended to accepts invalid block
proc setBlock*(c: ChainRef; blk: EthBlock): Result[void, string] =
  template header: BlockHeader = blk.header
  let dbTx = c.db.newTransaction()
  defer: dbTx.dispose()

  c.com.hardForkTransition(header)

  # Needed for figuring out whether KVT cleanup is due (see at the end)
  let
    vmState = c.getVmState(header).valueOr:
      return err("no vmstate")
    stateRootChpt = vmState.parent.stateRoot # Check point
  ? vmState.processBlock(blk)

  try:
    c.db.persistHeaderToDb(
      header, c.com.consensus == ConsensusType.POS, c.com.startOfHistory)
    discard c.db.persistTransactions(header.number, blk.transactions)
    discard c.db.persistReceipts(vmState.receipts)

    if blk.withdrawals.isSome:
      discard c.db.persistWithdrawals(blk.withdrawals.get)
  except CatchableError as exc:
    return err(exc.msg)

  # update currentBlock *after* we persist it
  # so the rpc return consistent result
  # between eth_blockNumber and eth_syncing
  c.com.syncCurrent = header.number

  dbTx.commit()

  # The `c.db.persistent()` call is ignored by the legacy DB which
  # automatically saves persistently when reaching the zero level transaction.
  #
  # For the `Aristo` database, this code position is only reached if the
  # the parent state of the first block (as registered in `headers[0]`) was
  # the canonical state before updating. So this state will be saved with
  # `persistent()` together with the respective block number.
  c.db.persistent(header.number - 1)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
