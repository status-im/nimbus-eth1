# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../constants,
  ../../db/[db_chain, accounts_cache],
  ../../transaction,
  ../../utils,
  ../../vm_state,
  ../../vm_types,
  ../clique,
  ../dao,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  chronicles,
  eth/[common, trie/db],
  nimcrypto

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc procBlkPreamble(vmState: BaseVMState; dbTx: DbTransaction;
                     header: BlockHeader, body: BlockBody): bool
                       {.gcsafe, raises: [Defect,CatchableError].} =
  if vmState.chainDB.config.daoForkSupport and
     vmState.chainDB.config.daoForkBlock == header.blockNumber:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  if body.transactions.calcTxRoot != header.txRoot:
    debug "Mismatched txRoot",
      blockNumber = header.blockNumber
    return false

  if header.txRoot != BLANK_ROOT_HASH:
    if body.transactions.len == 0:
      debug "No transactions in body",
        blockNumber = header.blockNumber
      return false
    else:
      #trace "Has transactions",
      #  blockNumber = header.blockNumber,
      #  blockHash = header.blockHash
      vmState.receipts = newSeq[Receipt](body.transactions.len)
      vmState.cumulativeGasUsed = 0
      for txIndex, tx in body.transactions:
        var sender: EthAddress
        if tx.getSender(sender):
          discard tx.processTransaction(sender, vmState)
        else:
          debug "Could not get sender",
            txIndex, tx
          return false
        vmState.receipts[txIndex] = vmState.makeReceipt(tx.txType)

  if vmState.cumulativeGasUsed != header.gasUsed:
    debug "gasUsed neq cumulativeGasUsed",
      gasUsed = header.gasUsed,
      cumulativeGasUsed = vmState.cumulativeGasUsed
    return false

  if header.ommersHash != EMPTY_UNCLE_HASH:
    let h = vmState.chainDB.persistUncles(body.uncles)
    if h != header.ommersHash:
      debug "Uncle hash mismatch"
      return false

  return true


proc procBlkEpilogue(vmState: BaseVMState; dbTx: DbTransaction;
                     header: BlockHeader, body: BlockBody): bool
                       {.gcsafe, raises: [Defect,RlpError].} =
  # Reward beneficiary
  vmState.mutateStateDB:
    if vmState.generateWitness:
      db.collectWitnessData()
    db.persist(ClearCache in vmState.flags)

  let stateDb = vmState.stateDB
  if header.stateRoot != stateDb.rootHash:
    debug "wrong state root in block",
      blockNumber = header.blockNumber,
      expected = header.stateRoot,
      actual = stateDb.rootHash,
      arrivedFrom = vmState.chainDB.getCanonicalHead().stateRoot
    return false

  let bloom = createBloom(vmState.receipts)
  if header.bloom != bloom:
    debug "wrong bloom in block",
      blockNumber = header.blockNumber
    return false

  let receiptRoot = calcReceiptRoot(vmState.receipts)
  if header.receiptRoot != receiptRoot:
    debug "wrong receiptRoot in block",
      blockNumber = header.blockNumber,
      actual = receiptRoot,
      expected = header.receiptRoot
    return false

  return true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processBlockNotPoA*(vmState: BaseVMState;
                         header: BlockHeader, body: BlockBody): ValidationResult
                     {.gcsafe, raises: [Defect,CatchableError].} =
  ## Processes `(header,body)` pair for a non-PoA network, only. This function
  ## will fail when applied to a PoA network like `Goerli`.
  if vmState.chainDB.config.poaEngine:
    # PoA consensus engine unsupported, see the other version of
    # processBlock() below
    debug "Unsupported PoA request"
    return ValidationResult.Error

  var dbTx = vmState.chainDB.db.beginTransaction()
  defer: dbTx.dispose()

  if not vmState.procBlkPreamble(dbTx, header, body):
    return ValidationResult.Error

  vmState.calculateReward(header, body)

  if not vmState.procBlkEpilogue(dbTx, header, body):
    return ValidationResult.Error

  # `applyDeletes = false`
  # If the trie pruning activated, each of the block will have its own state
  # trie keep intact, rather than destroyed by trie pruning. But the current
  # block will still get a pruned trie. If trie pruning deactivated,
  # `applyDeletes` have no effects.
  dbTx.commit(applyDeletes = false)


proc processBlock*(vmState: BaseVMState; poa: Clique;
                   header: BlockHeader, body: BlockBody): ValidationResult
                     {.gcsafe, raises: [Defect,CatchableError].} =
  ## Generalised function to processes `(header,body)` pair for any network,
  ## regardless of PoA or not. Currently there is no mining support so this
  ## function is mostly the same as `processBlockNotPoA()`.
  ##
  ## Rather than calculating the PoA state change here, it is done with the
  ## verification in the `chain/persist_blocks.persistBlocks()` method. So
  ## the `poa` descriptor is currently unused and only provided for later
  ## implementations (but can be savely removed, as well.)

  # # Process PoA state transition first so there is no need to re-wind on
  # # an error.
  # if vmState.chainDB.config.poaEngine and
  #    not poa.updatePoaState(header, body):
  #   debug "PoA update failed"
  #   return ValidationResult.Error

  var dbTx = vmState.chainDB.db.beginTransaction()
  defer: dbTx.dispose()

  if not vmState.procBlkPreamble(dbTx, header, body):
    return ValidationResult.Error

  if not vmState.chainDB.config.poaEngine:
    vmState.calculateReward(header, body)

  if not vmState.procBlkEpilogue(dbTx, header, body):
    return ValidationResult.Error

  dbTx.commit(applyDeletes = false)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
