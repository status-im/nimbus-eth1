import ../db/[db_chain, state_db], ../transaction, eth_common,
  ../vm_state, ../vm_types, ../vm_state_transactions, ranges,
  chronicles, ../vm/[computation, interpreter_dispatch, message],
  ../rpc/hexstrings, byteutils, nimcrypto,
  ../utils, ../constants

proc processTransaction*(db: var AccountStateDB, t: Transaction, sender: EthAddress, vmState: BaseVMState): UInt256 =
  ## Process the transaction, write the results to db.
  ## Returns amount of ETH to be rewarded to miner
  trace "Sender", sender
  trace "txHash", rlpHash = t.rlpHash
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
      return applyCreateTransaction(db, t, vmState, sender)

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
        let msg = newMessage(t.gasLimit, t.gasPrice, t.to, sender, t.value, t.payload, code.toSeq)
        # TODO: Run the vm

  if gasUsed > t.gasLimit:
    gasUsed = t.gasLimit

  var refund = (t.gasLimit - gasUsed).u256 * t.gasPrice.u256
  if transactionFailed:
    refund += t.value

  db.addBalance(sender, refund)
  return gasUsed.u256 * t.gasPrice.u256


proc processBlock*(chainDB: BaseChainDB, head, header: BlockHeader, body: BlockBody, vmState: BaseVMState): bool =
  let blockReward = 5.u256 * pow(10.u256, 18) # 5 ETH

  var stateDb = newAccountStateDB(c.db.db, head.stateRoot, c.db.pruneTrie)
  var receipts = newSeq[Receipt](bodies[i].transactions.len)

  if bodies[i].transactions.calcTxRoot != headers[i].txRoot:
    debug "Mismatched txRoot", i
    return ValidationResult.Error

  if headers[i].txRoot != BLANK_ROOT_HASH:
    let vmState = newBaseVMState(head, c.db)
    if bodies[i].transactions.len == 0:
      debug "No transactions in body", i
      return ValidationResult.Error
    else:
      trace "Has transactions", blockNumber = headers[i].blockNumber, blockHash = headers[i].blockHash

      var cumulativeGasUsed = GasInt(0)
      for txIndex, tx in bodies[i].transactions:
        var sender: EthAddress
        if tx.getSender(sender):
          let txFee = processTransaction(stateDb, tx, sender, vmState)

          # perhaps this can be altered somehow
          # or processTransaction return only gasUsed
          # a `div` here is ugly and possibly div by zero
          let gasUsed = (txFee div tx.gasPrice.u256).truncate(GasInt)
          cumulativeGasUsed += gasUsed

          # miner fee
          stateDb.addBalance(headers[i].coinbase, txFee)
        else:
          debug "Could not get sender", i, tx
          return ValidationResult.Error
        receipts[txIndex] = makeReceipt(vmState, stateDb.rootHash, cumulativeGasUsed)

  var mainReward = blockReward
  if headers[i].ommersHash != EMPTY_UNCLE_HASH:
    let h = c.db.persistUncles(bodies[i].uncles)
    if h != headers[i].ommersHash:
      debug "Uncle hash mismatch"
      return ValidationResult.Error
    for u in 0 ..< bodies[i].uncles.len:
      var uncleReward = bodies[i].uncles[u].blockNumber + 8.u256
      uncleReward -= headers[i].blockNumber
      uncleReward = uncleReward * blockReward
      uncleReward = uncleReward div 8.u256
      stateDb.addBalance(bodies[i].uncles[u].coinbase, uncleReward)
      mainReward += blockReward div 32.u256

  # Reward beneficiary
  stateDb.addBalance(headers[i].coinbase, mainReward)

  if headers[i].stateRoot != stateDb.rootHash:
    error "Wrong state root in block", blockNumber = headers[i].blockNumber, expected = headers[i].stateRoot, actual = stateDb.rootHash, arrivedFrom = c.db.getCanonicalHead().stateRoot
    # this one is a show stopper until we are confident in our VM's
    # compatibility with the main chain
    raise(newException(Exception, "Wrong state root in block"))

  let bloom = createBloom(receipts)
  if headers[i].bloom != bloom:
    debug "wrong bloom in block", blockNumber = headers[i].blockNumber
  assert(headers[i].bloom == bloom)

  let receiptRoot = calcReceiptRoot(receipts)
  if headers[i].receiptRoot != receiptRoot:
    debug "wrong receiptRoot in block", blockNumber = headers[i].blockNumber, actual=receiptRoot, expected=headers[i].receiptRoot
  assert(headers[i].receiptRoot == receiptRoot)