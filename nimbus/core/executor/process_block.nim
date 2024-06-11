# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../utils/utils,
  ../../common/common,
  ../../constants,
  ../../db/ledger,
  ../../transaction,
  ../../vm_state,
  ../../vm_types,
  ../dao,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  chronicles,
  results

{.push raises: [].}

# Factored this out of procBlkPreamble so that it can be used directly for
# stateless execution of specific transactions.
proc processTransactions*(
    vmState: BaseVMState, header: BlockHeader, transactions: seq[Transaction]
): Result[void, string] =
  vmState.receipts = newSeq[Receipt](transactions.len)
  vmState.cumulativeGasUsed = 0

  for txIndex, tx in transactions:
    var sender: EthAddress
    if not tx.getSender(sender):
      return err("Could not get sender for tx with index " & $(txIndex))
    let rc = vmState.processTransaction(tx, sender, header)
    if rc.isErr:
      return err("Error processing tx with index " & $(txIndex) & ":" & rc.error)
    vmState.receipts[txIndex] = vmState.makeReceipt(tx.txType)
  ok()

proc procBlkPreamble(vmState: BaseVMState, blk: EthBlock): Result[void, string] =
  template header(): BlockHeader =
    blk.header

  if vmState.com.daoForkSupport and vmState.com.daoForkBlock.get == header.blockNumber:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  if blk.transactions.calcTxRoot != header.txRoot:
    return err("Mismatched txRoot")

  if vmState.determineFork >= FkCancun:
    if header.parentBeaconBlockRoot.isNone:
      return err("Post-Cancun block header must have parentBeaconBlockRoot")

    ?vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.get)
  else:
    if header.parentBeaconBlockRoot.isSome:
      return err("Pre-Cancun block header must not have parentBeaconBlockRoot")

  if header.txRoot != EMPTY_ROOT_HASH:
    if blk.transactions.len == 0:
      return err("Transactions missing from body")

    ?processTransactions(vmState, header, blk.transactions)
  elif blk.transactions.len > 0:
    return err("Transactions in block with empty txRoot")

  if vmState.determineFork >= FkShanghai:
    if header.withdrawalsRoot.isNone:
      return err("Post-Shanghai block header must have withdrawalsRoot")
    if blk.withdrawals.isNone:
      return err("Post-Shanghai block body must have withdrawals")

    for withdrawal in blk.withdrawals.get:
      vmState.stateDB.addBalance(withdrawal.address, withdrawal.weiAmount)
  else:
    if header.withdrawalsRoot.isSome:
      return err("Pre-Shanghai block header must not have withdrawalsRoot")
    if blk.withdrawals.isSome:
      return err("Pre-Shanghai block body must not have withdrawals")

  if vmState.cumulativeGasUsed != header.gasUsed:
    # TODO replace logging with better error
    debug "gasUsed neq cumulativeGasUsed",
      gasUsed = header.gasUsed, cumulativeGasUsed = vmState.cumulativeGasUsed
    return err("gasUsed mismatch")

  if header.ommersHash != EMPTY_UNCLE_HASH:
    let h = vmState.com.db.persistUncles(blk.uncles)
    if h != header.ommersHash:
      return err("ommersHash mismatch")
  elif blk.uncles.len > 0:
    return err("Uncles in block with empty uncle hash")

  ok()

proc procBlkEpilogue(vmState: BaseVMState, header: BlockHeader): Result[void, string] =
  # Reward beneficiary
  vmState.mutateStateDB:
    if vmState.collectWitnessData:
      db.collectWitnessData()

    db.persist(clearEmptyAccount = vmState.determineFork >= FkSpurious)

  let stateDB = vmState.stateDB
  if header.stateRoot != stateDB.rootHash:
    # TODO replace logging with better error
    debug "wrong state root in block",
      blockNumber = header.blockNumber,
      expected = header.stateRoot,
      actual = stateDB.rootHash,
      arrivedFrom = vmState.com.db.getCanonicalHead().stateRoot
    return err("stateRoot mismatch")

  let bloom = createBloom(vmState.receipts)
  if header.bloom != bloom:
    return err("bloom mismatch")

  let receiptRoot = calcReceiptRoot(vmState.receipts)
  if header.receiptRoot != receiptRoot:
    # TODO replace logging with better error
    debug "wrong receiptRoot in block",
      blockNumber = header.blockNumber,
      actual = receiptRoot,
      expected = header.receiptRoot
    return err("receiptRoot mismatch")

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processBlock*(
    vmState: BaseVMState, ## Parent environment of header/body block
    blk: EthBlock, ## Header/body block to add to the blockchain
): Result[void, string] =
  ## Generalised function to processes `blk` for any network.
  var dbTx = vmState.com.db.newTransaction()
  defer:
    dbTx.dispose()

  ?vmState.procBlkPreamble(blk)

  # EIP-3675: no reward for miner in POA/POS
  if vmState.com.consensus == ConsensusType.POW:
    vmState.calculateReward(blk.header, blk.uncles)

  ?vmState.procBlkEpilogue(blk.header)

  dbTx.commit()

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
