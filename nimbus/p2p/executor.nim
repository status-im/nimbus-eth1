import ../db/[db_chain, state_db], ../transaction, eth_common,
  ../vm_state, ../vm_types, ../vm_state_transactions, ranges,
  chronicles, ../vm/[computation, interpreter_dispatch, message],
  ../rpc/hexstrings, byteutils, nimcrypto

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
