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
  ../dao,
  ../eip6110,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  eth/common/[keys, transaction_utils],
  chronicles,
  results

type
  ProcessBlockFlag* = enum
    skipValidation
    skipReceipts
    skipUncles
    skipStateRootCheck
    skipPostExecBalCheck
  ProcessBlockFlags* = set[ProcessBlockFlag]

when compileOption("threads"):
  import ./process_block_parallel

template withSenderSerial(txs: openArray[Transaction], body: untyped) =
  for txIndex {.inject.}, tx {.inject.} in txs:
    let sender {.inject.} = tx.recoverSenderCached().valueOr(default(Address))
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

type
  BlockRequests* = object
    ## Execution requests (EIP-7685) carried by a block: the deposit logs
    ## (EIP-6110) plus the post-execution system-call request lists (EIP-7002,
    ## EIP-7251, and the Amsterdam builder deposit/exit requests). Empty before
    ## Prague.
    deposit*: seq[byte]
    withdrawal*: seq[byte]
    consolidation*: seq[byte]
    builderDeposit*: seq[byte]
    builderExit*: seq[byte]

proc processBlockRequests*(
    vmState: BaseVMState, reqs: var BlockRequests
): Result[void, string] =
  ## Dequeue the post-execution system-call request lists into `reqs`. These
  ## alter the state, so they must run before the state root is computed.
  ## Pre-Prague leaves `reqs` empty.
  if vmState.fork >= FkPrague:
    reqs.withdrawal = ?processDequeueWithdrawalRequests(vmState)
    reqs.consolidation = ?processDequeueConsolidationRequests(vmState)
    if vmState.fork >= FkAmsterdam:
      reqs.builderDeposit = ?processBuilderDepositRequests(vmState)
      reqs.builderExit = ?processBuilderExitRequests(vmState)
  ok()

func calcRequestsHash*(reqs: BlockRequests, fork: EVMFork): Hash32 =
  ## Hash of the execution requests (EIP-7685) carried by `reqs`.
  if fork >= FkAmsterdam:
    calcRequestsHash(
      (DEPOSIT_REQUEST_TYPE, reqs.deposit),
      (WITHDRAWAL_REQUEST_TYPE, reqs.withdrawal),
      (CONSOLIDATION_REQUEST_TYPE, reqs.consolidation),
      (BUILDER_DEPOSIT_REQUEST_TYPE, reqs.builderDeposit),
      (BUILDER_EXIT_REQUEST_TYPE, reqs.builderExit),
    )
  else:
    calcRequestsHash(
      (DEPOSIT_REQUEST_TYPE, reqs.deposit),
      (WITHDRAWAL_REQUEST_TYPE, reqs.withdrawal),
      (CONSOLIDATION_REQUEST_TYPE, reqs.consolidation),
    )

func executionRequests*(reqs: BlockRequests, fork: EVMFork): seq[seq[byte]] =
  ## The execution requests (EIP-7685) carried by `reqs`, each encoded as its
  ## request type byte followed by the request data, empty requests omitted.
  template append(reqType: byte, reqData: seq[byte]) =
    if reqData.len > 0:
      var encoded = newSeqOfCap[byte](reqData.len + 1)
      encoded.add reqType
      encoded.add reqData
      result.add move(encoded)

  append(DEPOSIT_REQUEST_TYPE, reqs.deposit)
  append(WITHDRAWAL_REQUEST_TYPE, reqs.withdrawal)
  append(CONSOLIDATION_REQUEST_TYPE, reqs.consolidation)
  if fork >= FkAmsterdam:
    append(BUILDER_DEPOSIT_REQUEST_TYPE, reqs.builderDeposit)
    append(BUILDER_EXIT_REQUEST_TYPE, reqs.builderExit)

proc processTransactions(
    vmState: BaseVMState,
    header: Header,
    transactions: seq[Transaction],
    blockAccessList = Opt.none(BlockAccessListRef),
    flags: ProcessBlockFlags = {},
): Result[void, string] =
  if header.txRoot == EMPTY_ROOT_HASH:
    if transactions.len > 0:
        return err("Transactions in block with empty txRoot")
    return ok()

  if transactions.len == 0:
    return err("Transactions missing from body")

  let
    skipReceipts = skipReceipts in flags
    collectLogs = header.requestsHash.isSome and skipValidation notin flags

  vmState.receipts.setLen(if skipReceipts: 0 else: transactions.len)
  vmState.receiptBlooms.setLen(vmState.receipts.len)
  vmState.cumulativeGasUsed = 0
  vmState.blockExecutionGasUsed = 0
  vmState.blockStateGasUsed = 0
  vmState.blobGasUsed = 0'u64
  vmState.depositReqs.setLen(0)

  when compileOption("threads"):
    if vmState.com.balParallelExecutionEnabled(header.timestamp, blockAccessList):
      return processTransactionsParallel(
        vmState, transactions, blockAccessList.get(), skipReceipts, collectLogs)

  let depositContractAddress = vmState.com.depositContractAddress
  vmState.withSender(transactions, blockAccessList):
    # Accept a frame transaction sent from the zero address,
    # whose code approves execution and payment.
    if tx.txType != TxEip8141 and sender == default(Address):
      return err("Could not get sender for tx with index " & $(txIndex))

    if vmState.balTrackerEnabled:
      vmState.balTracker.setBlockAccessIndex(txIndex + 1)

    var rc = vmState.processTransaction(tx, sender)
    if rc.isErr:
      return err("Error processing tx with index " & $(txIndex) & ":" & rc.error)

    if collectLogs:
      ?parseDepositLogs(vmState.depositReqs, vmState.txLogs, depositContractAddress)

    if not skipReceipts:
      # calc logs bloom first, because makeReceipt will swallow vmState.txLogs
      vmState.receiptBlooms[txIndex] = calcLogsBloom(vmState.txLogs)
      vmState.receipts[txIndex] = vmState.makeReceipt(tx.txType)

  ok()

proc procBlkPreamble(
    vmState: BaseVMState,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef],
    flags: ProcessBlockFlags,
): Result[void, string] =
  template header(): Header =
    blk.header

  # Setup block access list tracker for pre‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.builder[].ensureIndexCount(blk.transactions.len() + 2, exact = true)
    vmState.balTracker.setBlockAccessIndex(0)
    vmState.balTracker.beginCallFrame()

  let com = vmState.com
  vmState.mutateLedger:
    if com.daoForkSupport and com.daoForkBlock.get == header.number:
      ledger.applyDAOHardFork()

  if skipValidation notin flags: # Expensive!
    if blk.transactions.calcTxRoot != header.txRoot:
      return err("Mismatched txRoot")

  if vmState.fork >= FkOsaka:
    if rlp.getEncodedLength(blk) > MAX_RLP_BLOCK_SIZE:
      return err("Post-Osaka block exceeded MAX_RLP_BLOCK_SIZE")

  if vmState.fork >= FkPrague:
    if header.requestsHash.isNone:
      return err("Post-Prague block header must have requestsHash")

    vmState.processParentBlockHash(header.parentHash)
  else:
    if header.requestsHash.isSome:
      return err("Pre-Prague block header must not have requestsHash")

  if vmState.fork >= FkCancun:
    if header.parentBeaconBlockRoot.isNone:
      return err("Post-Cancun block header must have parentBeaconBlockRoot")

    vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.value)
  else:
    if header.parentBeaconBlockRoot.isSome:
      return err("Pre-Cancun block header must not have parentBeaconBlockRoot")

  if vmState.fork >= FkAmsterdam:
    if header.blockAccessListHash.isNone:
      return err("Post-Amsterdam block header must have blockAccessListHash")
    if header.slotNumber.isNone:
      return err("Post-Amsterdam block header must have slotNumber")
  else:
    if header.blockAccessListHash.isSome:
      return err("Pre-Amsterdam block header must not have blockAccessListHash")
    if header.slotNumber.isSome:
      return err("Pre-Amsterdam block header must not have slotNumber")

  # Commit block access list tracker changes for pre‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

  ok()

proc procBlkEpilogue(
    vmState: BaseVMState,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef],
    flags: ProcessBlockFlags,
): Result[void, string] =
  template header(): Header =
    blk.header

  # Setup block access list tracker for post‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(blk.transactions.len() + 1)
    vmState.balTracker.beginCallFrame()

  # EIP-3675: no reward for miner in POA/POS
  if not vmState.com.proofOfStake(blk.header, vmState.ledger.txFrame):
    vmState.calculateReward(blk.header, blk.uncles)

  if vmState.fork >= FkShanghai:
    if header.withdrawalsRoot.isNone:
      return err("Post-Shanghai block header must have withdrawalsRoot")
    if blk.withdrawals.isNone:
      return err("Post-Shanghai block body must have withdrawals")

    if vmState.balTrackerEnabled:
      for withdrawal in blk.withdrawals.get:
        vmState.balTracker.trackAddBalanceChange(withdrawal.address, withdrawal.weiAmount)
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount, checkEmptyAccount = false)
    else:
      for withdrawal in blk.withdrawals.get:
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount, checkEmptyAccount = false)
  else:
    if header.withdrawalsRoot.isSome:
      return err("Pre-Shanghai block header must not have withdrawalsRoot")
    if blk.withdrawals.isSome:
      return err("Pre-Shanghai block body must not have withdrawals")

  if vmState.fork >= FkAmsterdam:
    let blockGasUsed = max(vmState.blockExecutionGasUsed, vmState.blockStateGasUsed)
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
    if skipUncles notin flags:
      let h = vmState.ledger.txFrame.persistUncles(blk.uncles)
      if h != header.ommersHash:
        return err("ommersHash mismatch")
    elif skipValidation notin flags and computeRlpHash(blk.uncles) != header.ommersHash:
      return err("ommersHash mismatch")
  elif blk.uncles.len > 0:
    return err("Uncles in block with empty uncle hash")

  # Execute EIP-7002 and EIP-7251 before calculating stateRoot because they
  # will alter the state
  var reqs: BlockRequests
  reqs.deposit = move vmState.depositReqs
  ?processBlockRequests(vmState, reqs)

  # Commit block access list tracker changes for post‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

  vmState.mutateLedger:
    # Clearing the account cache here helps manage its size when replaying
    # large ranges of blocks, implicitly limiting its size using the gas limit
    ledger.persist(
      clearEmptyAccounts = vmState.fork.clearEmptyAccounts(), clearCache = true
    )

  # Catch a fatal condition from the reward persist or the post-execution system
  # calls before getStateRoot below, which would otherwise assert on it.
  vmState.ledger.abortOnFatalError()

  if skipValidation notin flags:
    if skipPostExecBalCheck notin flags and vmState.fork >= FkAmsterdam:
      doAssert vmState.balTrackerEnabled

      let
        bal = vmState.balTracker.getBlockAccessList().get()
        matches =
          if blockAccessList.isSome():
            bal[] == blockAccessList.get()[]
          else:
            bal[].computeBlockAccessListHash() == header.blockAccessListHash.get
      if not matches:
        let balHash = bal[].computeBlockAccessListHash()
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

      if vmState.com.balPostExecValidation:
        bal.validate(header.blockAccessListHash.get, header.gasLimit).isOkOr:
          return err("blockAccessList failed post-execution validation: " & $error)

    if skipStateRootCheck notin flags:
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

    if skipReceipts notin flags:
      var bloom {.noinit.}: Bloom
      createBloom(vmState.receiptBlooms, bloom)

      if header.logsBloom != bloom:
        debug "wrong logsBloom in block",
          blockNumber = header.number, actual = bloom, expected = header.logsBloom
        return err("bloom mismatch")

      let receiptsRoot = calcReceiptsRoot(vmState.receipts, vmState.receiptBlooms)
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
      let requestsHash = calcRequestsHash(reqs, vmState.fork)

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
    flags: ProcessBlockFlags = {},
): Result[void, string] =
  ## Generalised function to processes `blk` for any network. A given
  ## `blockAccessList` must already have been validated against the header's
  ## `blockAccessListHash`.

  vmState.withBalPrefetch(blockAccessList):
    ?vmState.procBlkPreamble(blk, blockAccessList, flags)
    ?processTransactions(vmState, blk.header, blk.transactions, blockAccessList, flags)
    ?vmState.procBlkEpilogue(blk, blockAccessList, flags)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
