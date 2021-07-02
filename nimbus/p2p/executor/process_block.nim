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
  ../../config,
  ../../constants,
  ../../db/[db_chain, accounts_cache],
  ../../transaction,
  ../../utils,
  ../../vm_state,
  ../../vm_types,
  ../dao,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  ./update_poastate,
  chronicles,
  eth/[common, trie/db],
  nimcrypto


proc processBlock*(vmState: BaseVMState;
                   header: BlockHeader, body: BlockBody): ValidationResult =
  var
    chainDB = vmState.chaindb
    dbTx = chainDB.db.beginTransaction()
  defer: dbTx.dispose()

  if chainDB.config.daoForkSupport and header.blockNumber == chainDB.config.daoForkBlock:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  if body.transactions.calcTxRoot != header.txRoot:
    debug "Mismatched txRoot", blockNumber=header.blockNumber
    return ValidationResult.Error

  let fork = chainDB.config.toFork(vmState.blockNumber)

  if header.txRoot != BLANK_ROOT_HASH:
    if body.transactions.len == 0:
      debug "No transactions in body", blockNumber=header.blockNumber
      return ValidationResult.Error
    else:
      trace "Has transactions", blockNumber = header.blockNumber, blockHash = header.blockHash

      vmState.receipts = newSeq[Receipt](body.transactions.len)
      vmState.cumulativeGasUsed = 0
      for txIndex, tx in body.transactions:
        var sender: EthAddress
        if tx.getSender(sender):
          discard processTransaction(tx, sender, vmState, fork)
        else:
          debug "Could not get sender", txIndex, tx
          return ValidationResult.Error
        vmState.receipts[txIndex] = makeReceipt(vmState, fork, tx.txType)

  if vmState.cumulativeGasUsed != header.gasUsed:
    debug "gasUsed neq cumulativeGasUsed",
      gasUsed=header.gasUsed,
      cumulativeGasUsed=vmState.cumulativeGasUsed
    return ValidationResult.Error

  if header.ommersHash != EMPTY_UNCLE_HASH:
    let h = chainDB.persistUncles(body.uncles)
    if h != header.ommersHash:
      debug "Uncle hash mismatch"
      return ValidationResult.Error

  # PoA consensus engine have no reward for miner
  if not chainDB.config.poaEngine:
    vmState.calculateReward(fork, header, body)
  elif chainDB.updatePoaState(fork, header, body) == ValidationResult.Error:
    debug "PoA update failed"
    return ValidationResult.Error

  # Reward beneficiary
  vmState.mutateStateDB:
    if vmState.generateWitness:
      db.collectWitnessData()
    db.persist(ClearCache in vmState.flags)

  let stateDb = vmState.accountDb
  if header.stateRoot != stateDb.rootHash:
    debug "wrong state root in block", blockNumber=header.blockNumber, expected=header.stateRoot, actual=stateDb.rootHash, arrivedFrom=chainDB.getCanonicalHead().stateRoot
    return ValidationResult.Error

  let bloom = createBloom(vmState.receipts)
  if header.bloom != bloom:
    debug "wrong bloom in block", blockNumber=header.blockNumber
    return ValidationResult.Error

  let receiptRoot = calcReceiptRoot(vmState.receipts)
  if header.receiptRoot != receiptRoot:
    debug "wrong receiptRoot in block", blockNumber=header.blockNumber, actual=receiptRoot, expected=header.receiptRoot
    return ValidationResult.Error

  # `applyDeletes = false`
  # If the trie pruning activated, each of the block will have its own state trie keep intact,
  # rather than destroyed by trie pruning. But the current block will still get a pruned trie.
  # If trie pruning deactivated, `applyDeletes` have no effects.
  dbTx.commit(applyDeletes = false)

# End
