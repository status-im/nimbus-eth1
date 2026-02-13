# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  ../../common/common,
  ../../constants,
  ../../utils/utils,
  ../../db/ledger,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../../block_access_list/block_access_list_validation,
  ../dao,
  ../eip6110,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  eth/common/[keys, transaction_utils],
  chronicles,
  results

# TODO: make this a debug cli flag
const parallelTxExecutionEnabled = true

when compileOption("threads"):
  import taskpools

  template withSenderParallel(txs: openArray[Transaction], body: untyped, taskpool: Taskpool) =
    type Entry = (Signature, Hash32, Flowvar[Address])

    proc recoverTask(e: ptr Entry): Address {.nimcall.} =
      let pk = recover(e[][0], SkMessage(e[][1].data))
      if pk.isOk():
        pk[].to(Address)
      else:
        default(Address)

    var entries = newSeq[Entry](txs.len)

    # Prepare signature recovery tasks for each transaction - for simplicity,
    # we use `default(Address)` to signal sig check failure
    for i, e in entries.mpairs():
      e[0] = txs[i].signature().valueOr(default(Signature))
      e[1] = txs[i].rlpHashForSigning(txs[i].isEip155)
      let a = addr e
      # Spawning the task here allows it to start early, while we still haven't
      # hashed subsequent txs
      e[2] = taskpool.spawn recoverTask(a)

    for txIndex {.inject.}, e in entries.mpairs():
      template tx(): untyped =
        txs[txIndex]

      # Sync blocks until the sender is available from the task pool - as soon
      # as we have it, we can process this transaction while the senders of the
      # other transactions are being computed
      let sender {.inject.} = sync(e[2])

      body

  # TODO: improve function names and refactor
  proc processTransactionTask(
      vmState: BaseVMState,
      txIndex: int,
      tx: Transaction,
      header: Header,
      skipReceipts: bool,
      collectLogs: bool,
      blockAccessList: BlockAccessListRef
  ): Result[void, string] =
    let sender = tx.recoverSender().valueOr:
      return err("Could not get sender for tx with index " & $(txIndex))

    if vmState.balTrackerEnabled:
      vmState.balTracker.setBlockAccessIndex(txIndex + 1)

    let rc = vmState.processTransaction(tx, sender, header)
    if rc.isErr:
      return err("Error processing tx with index " & $(txIndex) & ":" & rc.error)
    if skipReceipts:
      # TODO don't generate logs at all if we're not going to put them in receipts
      if collectLogs:
        vmState.allLogs.add rc.value.logEntries
    else:
      vmState.receipts[txIndex] = vmState.makeReceipt(tx.txType, rc.value)
      if collectLogs:
        vmState.allLogs.add vmState.receipts[txIndex].logs

  # TODO: are pointers needed here
  proc processTransactionTask(
      blockVmState: ptr BaseVMState,
      txIndex: int,
      tx: ptr Transaction,
      header: ptr Header,
      skipReceipts: bool,
      collectLogs: bool,
      blockAccessList: ptr BlockAccessListRef
  ): Result[void, void] =

    # For now setup a separate vmState per transaction lazily.
    # This will likely be very slow and so this will be refactored away
    # later once more of the types are made thread safe.
    let txVmState = BaseVMState()
    txVmState.init(
      blockVmState[].parent,
      header[],
      blockVmState[].com,
      blockVmState[].ledger.txFrame,
      enableBalTracker = false # manually setup the bal tracker
    )

    # Setup ledger
    let txLedger = LedgerRef.init(
      blockVmState[].ledger.txFrame,
      blockVmState[].ledger.storeSlotHash,
      collectWitness = false)

    # Apply prestate to ledger

    # Setup bal tracker
    # the same thread safe builder instance is shared between all trackers
    if blockVmState[].balTrackerEnabled():
      txVmState.balTracker = BlockAccessListTrackerRef.init(
        txLedger.ReadOnlyLedger,
        blockVmState[].balTracker.builder
      )

    processTransactionTask(
      txVmState,
      txIndex,
      tx[],
      header[],
      skipReceipts,
      collectLogs,
      blockAccessList[]).isOkOr:
        return err()

    ok()

  proc processTransactionsParallel(
      vmState: BaseVMState,
      header: Header,
      transactions: seq[Transaction],
      skipReceipts: bool,
      collectLogs: bool,
      blockAccessList: Opt[BlockAccessListRef]
  ): Result[void, string] =
    doAssert not vmState.com.taskpool.isNil()
    doAssert blockAccessList.isSome()

    vmState.receipts.setLen(if skipReceipts: 0 else: transactions.len)
    vmState.cumulativeGasUsed = 0
    vmState.blockGasUsed = 0
    vmState.allLogs = @[]

    let bal = blockAccessList.get()
    var futs = newSeq[Flowvar[Result[void, void]]](transactions.len)

    # Submit all transaction processing tasks to the taskpool
    for txIndex, tx in transactions:
      futs[txIndex] = vmState.com.taskpool.spawn processTransactionTask(
        vmState.addr, txIndex, tx.addr, header.addr, skipReceipts, collectLogs, bal.addr)

    # Wait for all tasks to complete
    for txIndex, f in futs:
      sync(f).isOkOr:
        return err("parallel tx execution failed for transaction with index: " & $txIndex)

    ok()

template withSenderSerial(txs: openArray[Transaction], body: untyped) =
  for txIndex {.inject.}, tx {.inject.} in txs:
    let sender {.inject.} = tx.recoverSender().valueOr(default(Address))
    body

template withSender(vmState: BaseVMState, txs: openArray[Transaction], body: untyped) =
  when compileOption("threads"):
    # Execute transactions offloading the signature checking to the task pool if
    # it's available
    if vmState.com.taskpool == nil:
      withSenderSerial(txs, body)
    else:
      withSenderParallel(txs, body, vmState.com.taskpool)
  else:
    withSenderSerial(txs, body)

proc processTransactionsSerial(
    vmState: BaseVMState,
    header: Header,
    transactions: seq[Transaction],
    skipReceipts = false,
    collectLogs = false
): Result[void, string] =
  vmState.receipts.setLen(if skipReceipts: 0 else: transactions.len)
  vmState.cumulativeGasUsed = 0
  vmState.blockGasUsed = 0
  vmState.allLogs = @[]

  vmState.withSender(transactions):
    if sender == default(Address):
      return err("Could not get sender for tx with index " & $(txIndex))

    if vmState.balTrackerEnabled:
      vmState.balTracker.setBlockAccessIndex(txIndex + 1)

    let rc = vmState.processTransaction(tx, sender, header)
    if rc.isErr:
      return err("Error processing tx with index " & $(txIndex) & ":" & rc.error)
    if skipReceipts:
      # TODO don't generate logs at all if we're not going to put them in
      #      receipts
      if collectLogs:
        vmState.allLogs.add rc.value.logEntries
    else:
      vmState.receipts[txIndex] = vmState.makeReceipt(tx.txType, rc.value)
      if collectLogs:
        vmState.allLogs.add vmState.receipts[txIndex].logs
  ok()

proc processTransactions(
    vmState: BaseVMState,
    header: Header,
    transactions: seq[Transaction],
    skipReceipts: bool,
    collectLogs: bool,
    blockAccessList: Opt[BlockAccessListRef]
): Result[void, string] =
  when compileOption("threads"):
    if parallelTxExecutionEnabled:
      vmState.processTransactionsParallel(header, transactions, skipReceipts, collectLogs, blockAccessList)
    else:
      vmState.processTransactionsSerial(header, transactions, skipReceipts, collectLogs)
  else:
    vmState.processTransactionsSerial(header, transactions, skipReceipts, collectLogs)

proc procBlkPreamble(
    vmState: BaseVMState,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef],
    skipValidation, skipReceipts, skipUncles: bool,
): Result[void, string] =
  template header(): Header =
    blk.header

  # Setup block access list tracker for pre‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(0)
    vmState.balTracker.beginCallFrame()

  let com = vmState.com
  if com.daoForkSupport and com.daoForkBlock.get == header.number:
    vmState.mutateLedger:
      db.applyDAOHardFork()

  if not skipValidation: # Expensive!
    if blk.transactions.calcTxRoot != header.txRoot:
      return err("Mismatched txRoot")

  if com.isOsakaOrLater(header.timestamp):
    if rlp.getEncodedLength(blk) > MAX_RLP_BLOCK_SIZE:
      return err("Post-Osaka block exceeded MAX_RLP_BLOCK_SIZE")

  if com.isPragueOrLater(header.timestamp):
    if header.requestsHash.isNone:
      return err("Post-Prague block header must have requestsHash")

    ?vmState.processParentBlockHash(header.parentHash)
  else:
    if header.requestsHash.isSome:
      return err("Pre-Prague block header must not have requestsHash")

  if com.isCancunOrLater(header.timestamp):
    if header.parentBeaconBlockRoot.isNone:
      return err("Post-Cancun block header must have parentBeaconBlockRoot")

    ?vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.get)
  else:
    if header.parentBeaconBlockRoot.isSome:
      return err("Pre-Cancun block header must not have parentBeaconBlockRoot")

  if com.isAmsterdamOrLater(header.timestamp):
    if header.blockAccessListHash.isNone:
      return err("Post-Amsterdam block header must have blockAccessListHash")
  else:
    if header.blockAccessListHash.isSome:
      return err("Pre-Amsterdam block header must not have blockAccessListHash")

  # Commit block access list tracker changes for pre‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

  if header.txRoot != EMPTY_ROOT_HASH:
    if blk.transactions.len == 0:
      return err("Transactions missing from body")

    let collectLogs = header.requestsHash.isSome and not skipValidation
    ?processTransactions(
      vmState, header, blk.transactions, skipReceipts, collectLogs, blockAccessList
    )
  elif blk.transactions.len > 0:
    return err("Transactions in block with empty txRoot")

  # Setup block access list tracker for post‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(blk.transactions.len() + 1)
    vmState.balTracker.beginCallFrame()

  if com.isShanghaiOrLater(header.timestamp):
    if header.withdrawalsRoot.isNone:
      return err("Post-Shanghai block header must have withdrawalsRoot")
    if blk.withdrawals.isNone:
      return err("Post-Shanghai block body must have withdrawals")

    if vmState.balTrackerEnabled:
      for withdrawal in blk.withdrawals.get:
        vmState.balTracker.trackAddBalanceChange(withdrawal.address, withdrawal.weiAmount)
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount)
    else:
      for withdrawal in blk.withdrawals.get:
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount)
  else:
    if header.withdrawalsRoot.isSome:
      return err("Pre-Shanghai block header must not have withdrawalsRoot")
    if blk.withdrawals.isSome:
      return err("Pre-Shanghai block body must not have withdrawals")

  if com.isAmsterdamOrLater(header.timestamp):
    if vmState.blockGasUsed != header.gasUsed:
      # TODO replace logging with better error
      debug "gasUsed neq blockGasUsed",
        gasUsed = header.gasUsed, blockGasUsed = vmState.blockGasUsed
      return err("gasUsed mismatch")
  else:
    if vmState.cumulativeGasUsed != header.gasUsed:
      # TODO replace logging with better error
      debug "gasUsed neq cumulativeGasUsed",
        gasUsed = header.gasUsed, cumulativeGasUsed = vmState.cumulativeGasUsed
      return err("gasUsed mismatch")

  if header.ommersHash != EMPTY_UNCLE_HASH:
    # TODO It's strange that we persist uncles before processing block but the
    #      rest after...
    if not skipUncles:
      let h = vmState.ledger.txFrame.persistUncles(blk.uncles)
      if h != header.ommersHash:
        return err("ommersHash mismatch")
    elif not skipValidation and computeRlpHash(blk.uncles) != header.ommersHash:
      return err("ommersHash mismatch")
  elif blk.uncles.len > 0:
    return err("Uncles in block with empty uncle hash")

  ok()

proc procBlkEpilogue(
    vmState: BaseVMState,
    blk: Block,
    skipValidation: bool,
    skipReceipts: bool,
    skipStateRootCheck: bool,
    skipPostExecBalCheck: bool
): Result[void, string] =
  template header(): Header =
    blk.header

  # Reward beneficiary
  vmState.mutateLedger:
    # Clearing the account cache here helps manage its size when replaying
    # large ranges of blocks, implicitly limiting its size using the gas limit
    db.persist(
      clearEmptyAccount = vmState.com.isSpuriousOrLater(header.number, header.timestamp),
      clearCache = true
    )

  var
    withdrawalReqs: seq[byte]
    consolidationReqs: seq[byte]

  if header.requestsHash.isSome:
    # Execute EIP-7002 and EIP-7251 before calculating stateRoot
    # because they will alter the state
    withdrawalReqs = ?processDequeueWithdrawalRequests(vmState)
    consolidationReqs = ?processDequeueConsolidationRequests(vmState)

  if not skipValidation:
    if not skipPostExecBalCheck and vmState.com.isAmsterdamOrLater(header.timestamp):
      doAssert vmState.balTrackerEnabled
      # Commit block access list tracker changes for post‑execution system calls
      vmState.balTracker.commitCallFrame()

      let
        bal = vmState.balTracker.getBlockAccessList().get()
        balHash = bal[].computeBlockAccessListHash()
      if header.blockAccessListHash.get != balHash:
        debug "wrong blockAccessListHash, generated block access list does not " &
          "match expected blockAccessListHash in header",
          blockNumber = header.number,
          blockHash = header.computeBlockHash,
          parentHash = header.parentHash,
          expected = header.blockAccessListHash.get,
          actual = balHash,
          blockAccessList = $(bal[])
        return err("blockAccessListHash mismatch, expect: " &
          $header.blockAccessListHash.get & ", got: " & $balHash)

    if not skipStateRootCheck:
      let stateRoot = vmState.ledger.getStateRoot()
      if header.stateRoot != stateRoot:
        # TODO replace logging with better error
        debug "wrong stateRoot in block",
          blockNumber = header.number,
          blockHash = header.computeBlockHash,
          parentHash = header.parentHash,
          expected = header.stateRoot,
          actual = stateRoot,
          parentStateRoot = vmState.parent.stateRoot
        return
          err("stateRoot mismatch, expect: " & $header.stateRoot & ", got: " & $stateRoot)

    if not skipReceipts:
      let bloom = createBloom(vmState.receipts)

      if header.logsBloom != bloom:
        debug "wrong logsBloom in block",
          blockNumber = header.number, actual = bloom, expected = header.logsBloom
        return err("bloom mismatch")

      let receiptsRoot = calcReceiptsRoot(vmState.receipts)
      if header.receiptsRoot != receiptsRoot:
        # TODO replace logging with better error
        debug "wrong receiptRoot in block",
          blockNumber = header.number,
          parentHash = header.parentHash.short,
          blockHash = header.computeBlockHash.short,
          actual = receiptsRoot,
          expected = header.receiptsRoot
        return err("receiptRoot mismatch")

    if header.requestsHash.isSome:
      let
        depositReqs =
          ?parseDepositLogs(vmState.allLogs, vmState.com.depositContractAddress)
        requestsHash = calcRequestsHash(
          [
            (DEPOSIT_REQUEST_TYPE, depositReqs),
            (WITHDRAWAL_REQUEST_TYPE, withdrawalReqs),
            (CONSOLIDATION_REQUEST_TYPE, consolidationReqs),
          ]
        )

      if header.requestsHash.get != requestsHash:
        debug "wrong requestsHash in block",
          blockNumber = header.number,
          parentHash = header.parentHash.short,
          blockHash = header.computeBlockHash.short,
          actual = requestsHash,
          expected = header.requestsHash.get
        return err("requestsHash mismatch")

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processBlock*(
    vmState: BaseVMState, ## Parent environment of header/body block
    blk: Block, ## Header/body block to add to the blockchain
    blockAccessList = Opt.none(BlockAccessListRef),
    skipValidation = false,
    skipReceipts = false,
    skipUncles = false,
    skipStateRootCheck = false,
    skipPostExecBalCheck = false,
): Result[void, string] =
  ## Generalised function to processes `blk` for any network.
  ?vmState.procBlkPreamble(blk, blockAccessList, skipValidation, skipReceipts, skipUncles)

  # EIP-3675: no reward for miner in POA/POS
  if not vmState.com.proofOfStake(blk.header, vmState.ledger.txFrame):
    vmState.calculateReward(blk.header, blk.uncles)

  ?vmState.procBlkEpilogue(blk, skipValidation, skipReceipts, skipStateRootCheck, skipPostExecBalCheck)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
