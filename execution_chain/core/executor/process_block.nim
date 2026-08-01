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
  ../../db/core_db,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../../block_access_list/[bal_tracker, bal_validation],
  ../eip6110,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  ./process_system_calls,
  eth/common/[keys, transaction_utils],
  chronicles,
  results

when compileOption("threads"):
  import ./process_block_parallel

template withSenderSerial(txs: openArray[Transaction], body: untyped) =
  for txIndex {.inject.}, tx {.inject.} in txs:
    let sender {.inject.} = tx.recoverSender().valueOr(default(Address))
    body

template withSender(
    vmState: BaseVMState, txs: openArray[Transaction],
    bal: Opt[BlockAccessListRef], body: untyped) =
  when compileOption("threads"):
    if vmState.com.parallelSenderRecoveryEnabled():
      withSenderParallel(vmState, txs, bal, body)
    else:
      withSenderSerial(txs, body)
  else:
    withSenderSerial(txs, body)

template withBalPrefetch(
    vmState: BaseVMState, bal: Opt[BlockAccessListRef], body: untyped) =
  when compileOption("threads"):
    if vmState.com.balStatePrefetchEnabled(vmState.blockCtx.timestamp, bal):
      withBalPrefetchParallel(vmState, bal, body)
    else:
      body
  else:
    body

proc processTransactions*(
    vmState: BaseVMState,
    transactions: seq[Transaction],
    blockAccessList = Opt.none(BlockAccessListRef),
    skipReceipts = false,
    collectLogs = false
): Result[void, string] =
  vmState.receipts.setLen(if skipReceipts: 0 else: transactions.len)
  vmState.cumulativeGasUsed = 0
  vmState.blockRegularGasUsed = 0
  vmState.blockStateGasUsed = 0
  vmState.blobGasUsed = 0'u64
  vmState.allLogs = @[]

  vmState.withSender(transactions, blockAccessList):
    if sender == default(Address):
      return err("Could not get sender for tx with index " & $(txIndex))

    if vmState.balTrackerEnabled:
      vmState.balTracker.setBlockAccessIndex(txIndex + 1)

    let rc = vmState.processTransaction(tx, sender)
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

proc procBlkPreamble(
    vmState: BaseVMState,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef],
    requests: var BlockRequests,
    skipValidation, skipReceipts, skipUncles: bool
): Result[void, string] =
  template header(): Header =
    blk.header

  let com = vmState.com

  if not skipValidation: # Expensive!
    if blk.transactions.calcTxRoot != header.txRoot:
      return err("Mismatched txRoot")

  if com.isOsakaOrLater(header.timestamp):
    if rlp.getEncodedLength(blk) > MAX_RLP_BLOCK_SIZE:
      return err("Post-Osaka block exceeded MAX_RLP_BLOCK_SIZE")

  if com.isPragueOrLater(header.timestamp):
    if header.requestsHash.isNone:
      return err("Post-Prague block header must have requestsHash")
  else:
    if header.requestsHash.isSome:
      return err("Pre-Prague block header must not have requestsHash")

  if com.isCancunOrLater(header.timestamp):
    if header.parentBeaconBlockRoot.isNone:
      return err("Post-Cancun block header must have parentBeaconBlockRoot")
  else:
    if header.parentBeaconBlockRoot.isSome:
      return err("Pre-Cancun block header must not have parentBeaconBlockRoot")

  if com.isAmsterdamOrLater(header.timestamp):
    if header.blockAccessListHash.isNone:
      return err("Post-Amsterdam block header must have blockAccessListHash")
  else:
    if header.blockAccessListHash.isSome:
      return err("Pre-Amsterdam block header must not have blockAccessListHash")

  if com.isShanghaiOrLater(header.timestamp):
    if header.withdrawalsRoot.isNone:
      return err("Post-Shanghai block header must have withdrawalsRoot")
    if blk.withdrawals.isNone:
      return err("Post-Shanghai block body must have withdrawals")
  else:
    if header.withdrawalsRoot.isSome:
      return err("Pre-Shanghai block header must not have withdrawalsRoot")
    if blk.withdrawals.isSome:
      return err("Pre-Shanghai block body must not have withdrawals")

  if header.txRoot != EMPTY_ROOT_HASH:
    if blk.transactions.len == 0:
      return err("Transactions missing from body")
  elif blk.transactions.len > 0:
    return err("Transactions in block with empty txRoot")

  # Reserve one block access index per transaction plus the two indexes used
  # by the pre and post execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.builder[].ensureIndexCount(blk.transactions.len() + 2, exact = true)

  let collectLogs = header.requestsHash.isSome and not skipValidation

  var parallelExecution = false
  when compileOption("threads"):
    parallelExecution =
      com.balParallelExecutionEnabled(header.timestamp, blockAccessList)
    if parallelExecution:
      requests = ?vmState.processBlockParallel(
        blk, blockAccessList.get(), skipReceipts, collectLogs
      )

  if not parallelExecution:
    vmState.processPreExecSystemCalls(header)

    if header.txRoot != EMPTY_ROOT_HASH:
      ?processTransactions(
        vmState, blk.transactions, blockAccessList, skipReceipts, collectLogs
      )

    requests = ?vmState.processPostExecSystemCalls(blk)

  if com.isAmsterdamOrLater(header.timestamp):
    let blockGasUsed = max(vmState.blockRegularGasUsed, vmState.blockStateGasUsed)
    if blockGasUsed != header.gasUsed:
      # TODO replace logging with better error
      debug "gasUsed neq blockGasUsed",
        gasUsed = header.gasUsed, blockGasUsed = blockGasUsed
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
    requests: BlockRequests,
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
    ledger.persist(
      clearEmptyAccount = vmState.com.isSpuriousOrLater(header.number, header.timestamp),
      clearCache = true
    )

  # Catch a fatal condition from the reward persist or the post-execution system
  # calls before getStateRoot below, which would otherwise assert on it.
  vmState.ledger.abortOnFatalError()

  if not skipValidation:
    if not skipPostExecBalCheck and vmState.com.isAmsterdamOrLater(header.timestamp):
      doAssert vmState.balTrackerEnabled

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
        requestsHash = if vmState.com.isAmsterdamOrLater(header.timestamp):
            calcRequestsHash(
              [
                (DEPOSIT_REQUEST_TYPE, depositReqs),
                (WITHDRAWAL_REQUEST_TYPE, requests.withdrawalReqs),
                (CONSOLIDATION_REQUEST_TYPE, requests.consolidationReqs),
                (BUILDER_DEPOSIT_REQUEST_TYPE, requests.builderDepositReqs),
                (BUILDER_EXIT_REQUEST_TYPE, requests.builderExitReqs),
              ]
            )
          else:
            calcRequestsHash(
              [
                (DEPOSIT_REQUEST_TYPE, depositReqs),
                (WITHDRAWAL_REQUEST_TYPE, requests.withdrawalReqs),
                (CONSOLIDATION_REQUEST_TYPE, requests.consolidationReqs),
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

  vmState.withBalPrefetch(blockAccessList):
    var requests: BlockRequests
    ?vmState.procBlkPreamble(
      blk, blockAccessList, requests, skipValidation, skipReceipts, skipUncles)

    # EIP-3675: no reward for miner in POA/POS
    if not vmState.com.proofOfStake(blk.header, vmState.ledger.txFrame):
      vmState.calculateReward(blk.header, blk.uncles)

    ?vmState.procBlkEpilogue(
      blk, requests, skipValidation, skipReceipts, skipStateRootCheck,
      skipPostExecBalCheck)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
