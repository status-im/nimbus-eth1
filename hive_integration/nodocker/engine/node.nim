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
    core/clique,
    core/dao,
    core/validate,
    core/chain/chain_desc,
    core/executor/calculate_reward,
    core/executor/process_transaction,
    core/executor/process_block
  ],
  chronicles,
  stint,
  results

{.push raises: [].}

proc processBlock(
    vmState: BaseVMState;  ## Parent environment of header/body block
    header:  BlockHeader;  ## Header/body block to add to the blockchain
    body:    BlockBody): ValidationResult
    {.gcsafe, raises: [CatchableError].} =
  ## Generalised function to processes `(header,body)` pair for any network,
  ## regardless of PoA or not.
  ##
  ## Rather than calculating the PoA state change here, it is done with the
  ## verification in the `chain/persist_blocks.persistBlocks()` method. So
  ## the `poa` descriptor is currently unused and only provided for later
  ## implementations (but can be savely removed, as well.)
  ## variant of `processBlock()` where the `header` argument is explicitely set.

  var dbTx = vmState.com.db.beginTransaction()
  defer: dbTx.dispose()

  if vmState.com.daoForkSupport and
     vmState.com.daoForkBlock.get == header.blockNumber:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  if header.parentBeaconBlockRoot.isSome:
    let r = vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.get)
    if r.isErr:
      error("error in processing beaconRoot", err=r.error)

  let r = processTransactions(vmState, header, body.transactions)
  if r.isErr:
    error("error in processing transactions", err=r.error)

  if vmState.determineFork >= FkShanghai:
    for withdrawal in body.withdrawals.get:
      vmState.stateDB.addBalance(withdrawal.address, withdrawal.weiAmount)

  if header.ommersHash != EMPTY_UNCLE_HASH:
    discard vmState.com.db.persistUncles(body.uncles)

  # EIP-3675: no reward for miner in POA/POS
  if vmState.com.consensus == ConsensusType.POW:
    vmState.calculateReward(header, body)

  vmState.mutateStateDB:
    let clearEmptyAccount = vmState.determineFork >= FkSpurious
    db.persist(clearEmptyAccount, ClearCache in vmState.flags)

  # `applyDeletes = false`
  # If the trie pruning activated, each of the block will have its own state
  # trie keep intact, rather than destroyed by trie pruning. But the current
  # block will still get a pruned trie. If trie pruning deactivated,
  # `applyDeletes` have no effects.
  dbTx.commit(applyDeletes = false)

  ValidationResult.OK

proc getVmState(c: ChainRef, header: BlockHeader):
                 Result[BaseVMState, void]
                  {.gcsafe, raises: [CatchableError].} =
  if c.vmState.isNil.not:
    return ok(c.vmState)

  let vmState = BaseVMState()
  if not vmState.init(header, c.com):
    debug "Cannot initialise VmState",
      number = header.blockNumber
    return err()
  return ok(vmState)

# A stripped down version of persistBlocks without validation
# intended to accepts invalid block
proc setBlock*(c: ChainRef; header: BlockHeader;
                  body: BlockBody): ValidationResult
                          {.inline, raises: [CatchableError].} =
  let dbTx = c.db.beginTransaction()
  defer: dbTx.dispose()

  var cliqueState = c.clique.cliqueSave
  defer: c.clique.cliqueRestore(cliqueState)

  c.com.hardForkTransition(header)

  # Needed for figuring out whether KVT cleanup is due (see at the end)
  let
    vmState = c.getVmState(header).valueOr:
      return ValidationResult.Error
    stateRootChpt = vmState.parent.stateRoot # Check point
    validationResult = vmState.processBlock(header, body)

  if validationResult != ValidationResult.OK:
    return validationResult

  discard c.db.persistHeaderToDb(
    header, c.com.consensus == ConsensusType.POS, c.com.startOfHistory)
  discard c.db.persistTransactions(header.blockNumber, body.transactions)
  discard c.db.persistReceipts(vmState.receipts)

  if body.withdrawals.isSome:
    discard c.db.persistWithdrawals(body.withdrawals.get)

  # update currentBlock *after* we persist it
  # so the rpc return consistent result
  # between eth_blockNumber and eth_syncing
  c.com.syncCurrent = header.blockNumber

  dbTx.commit()

  # The `c.db.persistent()` call is ignored by the legacy DB which
  # automatically saves persistently when reaching the zero level transaction.
  #
  # For the `Aristo` database, this code position is only reached if the
  # the parent state of the first block (as registered in `headers[0]`) was
  # the canonical state before updating. So this state will be saved with
  # `persistent()` together with the respective block number.
  c.db.persistent(header.blockNumber - 1)

  ValidationResult.OK

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
