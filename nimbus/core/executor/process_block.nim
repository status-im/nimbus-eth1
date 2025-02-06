# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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
  ../../utils/utils,
  ../../constants,
  ../../db/ledger,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../dao,
  ../eip6110,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  eth/common/[keys, transaction_utils],
  chronicles,
  results,
  taskpools

template withSender(txs: openArray[Transaction], body: untyped) =
  # Execute transactions offloading the signature checking to the task pool if
  # it's available
  if taskpool == nil:
    for txIndex {.inject.}, tx {.inject.} in txs:
      let sender {.inject.} = tx.recoverSender().valueOr(default(Address))
      body
  else:
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

# Factored this out of procBlkPreamble so that it can be used directly for
# stateless execution of specific transactions.
proc processTransactions*(
    vmState: BaseVMState,
    header: Header,
    transactions: seq[Transaction],
    skipReceipts = false,
    collectLogs = false,
    taskpool: Taskpool = nil,
): Result[void, string] =
  vmState.receipts.setLen(if skipReceipts: 0 else: transactions.len)
  vmState.cumulativeGasUsed = 0
  vmState.allLogs = @[]

  withSender(transactions):
    if sender == default(Address):
      return err("Could not get sender for tx with index " & $(txIndex))

    let rc = vmState.processTransaction(tx, sender, header)
    if rc.isErr:
      return err("Error processing tx with index " & $(txIndex) & ":" & rc.error)
    if skipReceipts:
      # TODO don't generate logs at all if we're not going to put them in
      #      receipts
      if collectLogs:
        vmState.allLogs.add vmState.getAndClearLogEntries()
      else:
        discard vmState.getAndClearLogEntries()
    else:
      vmState.receipts[txIndex] = vmState.makeReceipt(tx.txType)
      if collectLogs:
        vmState.allLogs.add vmState.receipts[txIndex].logs
  ok()

proc procBlkPreamble(
    vmState: BaseVMState,
    blk: Block,
    skipValidation, skipReceipts, skipUncles: bool,
    taskpool: Taskpool,
): Result[void, string] =
  template header(): Header =
    blk.header

  let com = vmState.com
  if com.daoForkSupport and com.daoForkBlock.get == header.number:
    vmState.mutateLedger:
      db.applyDAOHardFork()

  if not skipValidation: # Expensive!
    if blk.transactions.calcTxRoot != header.txRoot:
      return err("Mismatched txRoot")

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

  if header.txRoot != EMPTY_ROOT_HASH:
    if blk.transactions.len == 0:
      return err("Transactions missing from body")

    let collectLogs = header.requestsHash.isSome and not skipValidation
    ?processTransactions(
      vmState, header, blk.transactions, skipReceipts, collectLogs, taskpool
    )
  elif blk.transactions.len > 0:
    return err("Transactions in block with empty txRoot")

  if com.isShanghaiOrLater(header.timestamp):
    if header.withdrawalsRoot.isNone:
      return err("Post-Shanghai block header must have withdrawalsRoot")
    if blk.withdrawals.isNone:
      return err("Post-Shanghai block body must have withdrawals")

    for withdrawal in blk.withdrawals.get:
      vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount)
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
    # TODO It's strange that we persist uncles before processing block but the
    #      rest after...
    if not skipUncles:
      let h = vmState.com.db.persistUncles(blk.uncles)
      if h != header.ommersHash:
        return err("ommersHash mismatch")
    elif not skipValidation and rlpHash(blk.uncles) != header.ommersHash:
      return err("ommersHash mismatch")
  elif blk.uncles.len > 0:
    return err("Uncles in block with empty uncle hash")

  ok()

proc procBlkEpilogue(
    vmState: BaseVMState, blk: Block, skipValidation: bool, skipReceipts: bool
): Result[void, string] =
  template header(): Header =
    blk.header

  # Reward beneficiary
  vmState.mutateLedger:
    if vmState.collectWitnessData:
      db.collectWitnessData()

    # Clearing the account cache here helps manage its size when replaying
    # large ranges of blocks, implicitly limiting its size using the gas limit
    db.persist(
      clearEmptyAccount = vmState.com.isSpuriousOrLater(header.number),
      clearCache = true,
    )

  var
    withdrawalReqs: seq[byte]
    consolidationReqs: seq[byte]

  if header.requestsHash.isSome:
    # Execute EIP-7002 and EIP-7251 before calculating stateRoot
    # because they will alter the state
    withdrawalReqs = processDequeueWithdrawalRequests(vmState)
    consolidationReqs = processDequeueConsolidationRequests(vmState)

  if not skipValidation:
    let stateRoot = vmState.ledger.getStateRoot()
    if header.stateRoot != stateRoot:
      # TODO replace logging with better error
      debug "wrong state root in block",
        blockNumber = header.number,
        blockHash = header.blockHash,
        parentHash = header.parentHash,
        expected = header.stateRoot,
        actual = stateRoot,
        arrivedFrom = vmState.parent.stateRoot
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
          blockHash = header.blockHash.short,
          actual = receiptsRoot,
          expected = header.receiptsRoot
        return err("receiptRoot mismatch")

    if header.requestsHash.isSome:
      let
        depositReqs =
          ?parseDepositLogs(vmState.allLogs, vmState.com.depositContractAddress)
        requestsHash = calcRequestsHash([
          (DEPOSIT_REQUEST_TYPE, depositReqs),
          (WITHDRAWAL_REQUEST_TYPE, withdrawalReqs),
          (CONSOLIDATION_REQUEST_TYPE, consolidationReqs)
        ])

      if header.requestsHash.get != requestsHash:
        debug "wrong requestsHash in block",
          blockNumber = header.number,
          parentHash = header.parentHash.short,
          blockHash = header.blockHash.short,
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
    skipValidation: bool = false,
    skipReceipts: bool = false,
    skipUncles: bool = false,
    taskpool: Taskpool = nil,
): Result[void, string] =
  ## Generalised function to processes `blk` for any network.
  ?vmState.procBlkPreamble(blk, skipValidation, skipReceipts, skipUncles, taskpool)

  # EIP-3675: no reward for miner in POA/POS
  if not vmState.com.proofOfStake(blk.header):
    vmState.calculateReward(blk.header, blk.uncles)

  ?vmState.procBlkEpilogue(blk, skipValidation, skipReceipts)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
