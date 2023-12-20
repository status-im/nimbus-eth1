# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
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
  ../clique,
  ../dao,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  chronicles,
  stew/results

{.push raises: [].}

import
  std/times,
  ../../../tests/replay/pp

var
  noisy* = false
  pbProfTotal*: (Duration, int)
  pbProfBeginTransaction*: (Duration, int)
  pbProfProcBlkPreamble*: (Duration, int)
  pbProfCalculateReward*: (Duration, int)
  pbProfProcBlkEpilogue*: (Duration, int)
  pbProfProcBlkEpilogueGenerateWitness*: (Duration, int)
  pbProfProcBlkEpilogueStateRoot*: (Duration, int)
  pbProfProcBlkEpilogueRootHash*: (Duration, int)
  pbProfProcBlkEpilogueBloom*: (Duration, int)
  pbProfProcBlkEpilogueReceiptRoot*: (Duration, int)
  pbProfCommit*: (Duration, int)

# Factored this out of procBlkPreamble so that it can be used directly for
# stateless execution of specific transactions.
proc processTransactions*(vmState: BaseVMState;
                          header: BlockHeader;
                          transactions: seq[Transaction]): Result[void, string]
    {.gcsafe, raises: [CatchableError].} =
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

proc procBlkPreamble(vmState: BaseVMState;
                     header: BlockHeader; body: BlockBody): bool
    {.gcsafe, raises: [CatchableError].} =

  if vmState.com.daoForkSupport and
     vmState.com.daoForkBlock.get == header.blockNumber:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  if body.transactions.calcTxRoot != header.txRoot:
    debug "Mismatched txRoot",
      blockNumber = header.blockNumber
    return false

  if vmState.determineFork >= FkCancun:
    if header.parentBeaconBlockRoot.isNone:
      raise ValidationError.newException("Post-Cancun block header must have parentBeaconBlockRoot")
  else:
    if header.parentBeaconBlockRoot.isSome:
      raise ValidationError.newException("Pre-Cancun block header must not have parentBeaconBlockRoot")

  if header.parentBeaconBlockRoot.isSome:
    let r = vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.get)
    if r.isErr:
      error("error in processing beaconRoot", err=r.error)

  if header.txRoot != EMPTY_ROOT_HASH:
    if body.transactions.len == 0:
      debug "No transactions in body",
        blockNumber = header.blockNumber
      return false
    else:
      let r = processTransactions(vmState, header, body.transactions)
      if r.isErr:
        error("error in processing transactions", err=r.error)

  if vmState.determineFork >= FkShanghai:
    if header.withdrawalsRoot.isNone:
      raise ValidationError.newException("Post-Shanghai block header must have withdrawalsRoot")
    if body.withdrawals.isNone:
      raise ValidationError.newException("Post-Shanghai block body must have withdrawals")

    for withdrawal in body.withdrawals.get:
      vmState.stateDB.addBalance(withdrawal.address, withdrawal.weiAmount)
  else:
    if header.withdrawalsRoot.isSome:
      raise ValidationError.newException("Pre-Shanghai block header must not have withdrawalsRoot")
    if body.withdrawals.isSome:
      raise ValidationError.newException("Pre-Shanghai block body must not have withdrawals")

  if vmState.cumulativeGasUsed != header.gasUsed:
    debug "gasUsed neq cumulativeGasUsed",
      gasUsed = header.gasUsed,
      cumulativeGasUsed = vmState.cumulativeGasUsed
    return false

  if header.ommersHash != EMPTY_UNCLE_HASH:
    let h = vmState.com.db.persistUncles(body.uncles)
    if h != header.ommersHash:
      debug "Uncle hash mismatch"
      return false

  true

proc procBlkEpilogue(vmState: BaseVMState;
                     header: BlockHeader; body: BlockBody): bool
    {.gcsafe, raises: [].} =

  # Reward beneficiary
  noisy.profileSection(
      "procBlkEpilogue.generateWitness", pbProfProcBlkEpilogueGenerateWitness):
    vmState.mutateStateDB:
      if vmState.generateWitness:
        db.collectWitnessData()
      let clearEmptyAccount = vmState.determineFork >= FkSpurious
      db.persist(clearEmptyAccount, ClearCache in vmState.flags)

  let stateDb = vmState.stateDB

  var stateRoot: Hash256
  noisy.profileSection(
      "procBlkEpilogue.stateRoot", pbProfProcBlkEpilogueStateRoot):
    stateRoot = header.stateRoot

  var rootHash: Hash256
  noisy.profileSection(
      "procBlkEpilogue.rootHash", pbProfProcBlkEpiloguerootHash):
    rootHash = stateDb.rootHash

  if stateRoot != rootHash:
    debug "wrong state root in block",
      blockNumber = header.blockNumber,
      expected = stateRoot,
      actual = rootHash,
      arrivedFrom = vmState.com.db.getCanonicalHead().stateRoot
    return false

  noisy.profileSection("procBlkEpilogue..bloom", pbProfProcBlkEpilogueBloom):
    let bloom = createBloom(vmState.receipts)
    if header.bloom != bloom:
      debug "wrong bloom in block",
        blockNumber = header.blockNumber
      return false

  noisy.profileSection(
      "procBlkEpilogue..receiptRoot", pbProfProcBlkEpilogueReceiptRoot):
    let receiptRoot = calcReceiptRoot(vmState.receipts)
    if header.receiptRoot != receiptRoot:
      debug "wrong receiptRoot in block",
        blockNumber = header.blockNumber,
        actual = receiptRoot,
        expected = header.receiptRoot
      return false

  true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processBlock*(
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

  noisy.profileSection("processBlock", pbProfTotal):
    var dbTx: CoreDbTxRef
    noisy.profileSection(
        "processBlock.beginTransaction", pbProfBeginTransaction):
      dbTx = vmState.com.db.beginTransaction()
    defer: dbTx.dispose()

    noisy.profileSection("procBlkPreamble", pbProfProcBlkPreamble):
      if not vmState.procBlkPreamble(header, body):
        if noisy: echo "+++ processBlock (1) fail #", header.blockNumber
        return ValidationResult.Error

    # EIP-3675: no reward for miner in POA/POS
    noisy.profileSection("calculateReward", pbProfCalculateReward):
      if vmState.com.consensus == ConsensusType.POW:
        vmState.calculateReward(header, body)

    noisy.profileSection("procBlkEpilogue", pbProfProcBlkEpilogue):
      if not vmState.procBlkEpilogue(header, body):
        if noisy: echo "+++ processBlock (2) fail #", header.blockNumber
        return ValidationResult.Error

    # `applyDeletes = false`
    # If the trie pruning activated, each of the block will have its own state
    # trie keep intact, rather than destroyed by trie pruning. But the current
    # block will still get a pruned trie. If trie pruning deactivated,
    # `applyDeletes` have no effects.
    noisy.profileSection("processBlock.commit", pbProfCommit):
      dbTx.commit(applyDeletes = false)

  ValidationResult.OK

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
