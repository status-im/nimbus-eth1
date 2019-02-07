import options,
  eth/[common, bloom], ranges, chronicles, nimcrypto,
  ../db/[db_chain, state_db],
  ../utils, ../constants, ../transaction,
  ../vm_state, ../vm_types, ../vm_state_transactions,
  ../vm/[computation, interpreter_dispatch, message],
  ../vm/interpreter/vm_forks

proc contractCall(t: Transaction, vmState: BaseVMState, sender: EthAddress, forkOverride=none(Fork)): UInt256 =
  # TODO: this function body was copied from GST with it's comments and TODOs.
  # Right now it's main purpose is to produce VM tracing when syncing block with
  # contract call. At later stage, this proc together with applyCreateTransaction
  # and processTransaction need to be restructured.

  # TODO: replace with cachingDb or similar approach; necessary
  # when calls/subcalls/etc come in, too.
  var db = vmState.accountDb
  let storageRoot = db.getStorageRoot(t.to)

  var computation = setupComputation(vmState, t, sender, forkOverride)
  # contract creation transaction.to == 0, so ensure happens after
  db.addBalance(t.to, t.value)

  let header = vmState.blockHeader
  let gasCost = t.gasLimit.u256 * t.gasPrice.u256

  if execComputation(computation):
    let
      gasRemaining = computation.gasMeter.gasRemaining.u256
      gasRefunded = computation.gasMeter.gasRefunded.u256
      gasUsed = t.gasLimit.u256 - gasRemaining
      gasRefund = min(gasRefunded, gasUsed div 2)
      gasRefundAmount = (gasRefund + gasRemaining) * t.gasPrice.u256

    db.addBalance(sender, gasRefundAmount)

    return (t.gasLimit.u256 - gasRemaining - gasRefund) * t.gasPrice.u256
  else:
    db.subBalance(t.to, t.value)
    db.addBalance(sender, t.value)
    db.setStorageRoot(t.to, storageRoot)
    if computation.tracingEnabled: computation.traceError()
    vmState.clearLogs()
    return t.gasLimit.u256 * t.gasPrice.u256

proc processTransaction*(t: Transaction, sender: EthAddress, vmState: BaseVMState): UInt256 =
  ## Process the transaction, write the results to db.
  ## Returns amount of ETH to be rewarded to miner
  trace "Sender", sender
  trace "txHash", rlpHash = t.rlpHash
  var db = vmState.accountDb
  # Inct nonce:
  db.setNonce(sender, db.getNonce(sender) + 1)
  var transactionFailed = false

  #t.dump

  # TODO: combine/refactor re validate
  let upfrontGasCost = t.gasLimit.u256 * t.gasPrice.u256
  let upfrontCost = upfrontGasCost + t.value
  var balance = db.getBalance(sender)
  if balance < upfrontCost:
    if balance <= upfrontGasCost:
      result = balance
      balance = 0.u256
    else:
      result = upfrontGasCost
      balance -= upfrontGasCost
    transactionFailed = true
  else:
    balance -= upfrontCost

  db.setBalance(sender, balance)
  if transactionFailed:
    return

  var gasUsed = t.payload.intrinsicGas.GasInt # += 32000 appears in Homestead when contract create

  if gasUsed > t.gasLimit:
    debug "Transaction failed. Out of gas."
    transactionFailed = true
  else:
    if t.isContractCreation:
      # TODO: re-derive sender in callee for cleaner interface, perhaps
      return applyCreateTransaction(t, vmState, sender)

    else:
      let code = db.getCode(t.to)
      if code.len == 0:
        # Value transfer
        trace "Transfer", value = t.value, sender, to = t.to

        db.addBalance(t.to, t.value)
      else:
        # Contract call
        trace "Contract call"
        trace "Transaction", sender, to = t.to, value = t.value, hasCode = code.len != 0
        #let msg = newMessage(t.gasLimit, t.gasPrice, t.to, sender, t.value, t.payload, code.toSeq)
        # TODO: Run the vm with proper fork
        return contractCall(t, vmState, sender)

  if gasUsed > t.gasLimit:
    gasUsed = t.gasLimit

  var refund = (t.gasLimit - gasUsed).u256 * t.gasPrice.u256
  if transactionFailed:
    refund += t.value

  db.addBalance(sender, refund)
  return gasUsed.u256 * t.gasPrice.u256

type
  # TODO: these types need to be removed
  # once eth/bloom and eth/common sync'ed
  Bloom = common.BloomFilter
  LogsBloom = bloom.BloomFilter

# TODO: move these three receipt procs below somewhere else more appropriate
func logsBloom(logs: openArray[Log]): LogsBloom =
  for log in logs:
    result.incl log.address
    for topic in log.topics:
      result.incl topic

func createBloom*(receipts: openArray[Receipt]): Bloom =
  var bloom: LogsBloom
  for receipt in receipts:
    bloom.value = bloom.value or logsBloom(receipt.logs).value
  result = bloom.value.toByteArrayBE

proc makeReceipt(vmState: BaseVMState, cumulativeGasUsed: GasInt, fork = FkFrontier): Receipt =
  if fork < FkByzantium:
    result.stateRootOrStatus = hashOrStatus(vmState.accountDb.rootHash)
  else:
    # TODO: post byzantium fork use status instead of rootHash
    let vmStatus = true # success or failure
    result.stateRootOrStatus = hashOrStatus(vmStatus)

  result.cumulativeGasUsed = cumulativeGasUsed
  result.logs = vmState.getAndClearLogEntries()
  result.bloom = logsBloom(result.logs).value.toByteArrayBE

proc prepareVMState(vmState: BaseVMState, header: BlockHeader) =
  # TODO: move this proc to somewhere else if it already complete

  # blockNumber returned from VM should be current block number
  # and not something else
  vmState.blockHeader.blockNumber = header.blockNumber

  # time stamp?
  # gas limit?
  # etc?

proc processBlock*(chainDB: BaseChainDB, head, header: BlockHeader, body: BlockBody, vmState: BaseVMState): ValidationResult =
  let blockReward = 5.u256 * pow(10.u256, 18) # 5 ETH

  if body.transactions.calcTxRoot != header.txRoot:
    debug "Mismatched txRoot", blockNumber=header.blockNumber
    return ValidationResult.Error

  prepareVMState(vmState, header)

  var stateDb = vmState.accountDb
  if header.txRoot != BLANK_ROOT_HASH:
    if body.transactions.len == 0:
      debug "No transactions in body", blockNumber=header.blockNumber
      return ValidationResult.Error
    else:
      trace "Has transactions", blockNumber = header.blockNumber, blockHash = header.blockHash

      vmState.receipts = newSeq[Receipt](body.transactions.len)
      var cumulativeGasUsed = GasInt(0)
      for txIndex, tx in body.transactions:
        var sender: EthAddress
        if tx.getSender(sender):
          let txFee = processTransaction(tx, sender, vmState)

          # perhaps this can be altered somehow
          # or processTransaction return only gasUsed
          # a `div` here is ugly and possibly div by zero
          let gasUsed = (txFee div tx.gasPrice.u256).truncate(GasInt)
          cumulativeGasUsed += gasUsed

          # miner fee
          stateDb.addBalance(header.coinbase, txFee)
        else:
          debug "Could not get sender", txIndex, tx
          return ValidationResult.Error
        vmState.receipts[txIndex] = makeReceipt(vmState, cumulativeGasUsed)

  var mainReward = blockReward
  if header.ommersHash != EMPTY_UNCLE_HASH:
    let h = chainDB.persistUncles(body.uncles)
    if h != header.ommersHash:
      debug "Uncle hash mismatch"
      return ValidationResult.Error
    for uncle in body.uncles:
      var uncleReward = uncle.blockNumber + 8.u256
      uncleReward -= header.blockNumber
      uncleReward = uncleReward * blockReward
      uncleReward = uncleReward div 8.u256
      stateDb.addBalance(uncle.coinbase, uncleReward)
      mainReward += blockReward div 32.u256

  # Reward beneficiary
  stateDb.addBalance(header.coinbase, mainReward)

  if header.stateRoot != stateDb.rootHash:
    error "Wrong state root in block", blockNumber=header.blockNumber, expected=header.stateRoot, actual=stateDb.rootHash, arrivedFrom=chainDB.getCanonicalHead().stateRoot
    # this one is a show stopper until we are confident in our VM's
    # compatibility with the main chain
    return ValidationResult.Error

  let bloom = createBloom(vmState.receipts)
  if header.bloom != bloom:
    debug "wrong bloom in block", blockNumber=header.blockNumber
    return ValidationResult.Error

  let receiptRoot = calcReceiptRoot(vmState.receipts)
  if header.receiptRoot != receiptRoot:
    debug "wrong receiptRoot in block", blockNumber=header.blockNumber, actual=receiptRoot, expected=header.receiptRoot
    return ValidationResult.Error
