import ../db/[db_chain, state_db], eth_common, chronicles, ../vm_state, ../vm_types, ../transaction, ranges,
  ../vm/[computation, interpreter_dispatch, message], ../constants, stint, nimcrypto,
  ../vm_state_transactions,
  eth_trie/db, eth_trie, rlp,
  sugar

type
  Chain* = ref object of AbstractChainDB
    db: BaseChainDB

proc newChain*(db: BaseChainDB): Chain =
  result.new
  result.db = db

method genesisHash*(c: Chain): KeccakHash =
  c.db.getBlockHash(0.toBlockNumber)

method getBlockHeader*(c: Chain, b: HashOrNum, output: var BlockHeader): bool =
  case b.isHash
  of true:
    c.db.getBlockHeader(b.hash, output)
  else:
    c.db.getBlockHeader(b.number, output)

method getBestBlockHeader*(c: Chain): BlockHeader =
  c.db.getCanonicalHead()

method getSuccessorHeader*(c: Chain, h: BlockHeader, output: var BlockHeader): bool =
  let n = h.blockNumber + 1
  c.db.getBlockHeader(n, output)

method getBlockBody*(c: Chain, blockHash: KeccakHash): BlockBodyRef =
  result = nil

proc processTransaction(db: var AccountStateDB, t: Transaction, sender: EthAddress, head: BlockHeader, chainDB: BaseChainDB): UInt256 =
  ## Process the transaction, write the results to db.
  ## Returns amount of ETH to be rewarded to miner
  echo "Sender: ", sender
  echo "txHash: ", t.rlpHash
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
    echo "Transaction failed. Out of gas."
    transactionFailed = true
  else:
    if t.isContractCreation:
      # TODO: re-derive sender in callee for cleaner interface, perhaps
      var vmState = newBaseVMState(head, chainDB)
      return applyCreateTransaction(db, t, head, vmState, sender)

    else:
      let code = db.getCode(t.to)
      if code.len == 0:
        # Value transfer
        echo "Transfer ", t.value, " from ", sender, " to ", t.to

        db.addBalance(t.to, t.value)
      else:
        # Contract call
        echo "Contract call"

        debug "Transaction", sender, to = t.to, value = t.value, hasCode = code.len != 0
        let msg = newMessage(t.gasLimit, t.gasPrice, t.to, sender, t.value, t.payload, code.toSeq)
        # TODO: Run the vm

  if gasUsed > t.gasLimit:
    gasUsed = t.gasLimit

  var refund = (t.gasLimit - gasUsed).u256 * t.gasPrice.u256
  if transactionFailed:
    refund += t.value

  db.addBalance(sender, refund)

  return gasUsed.u256 * t.gasPrice.u256

proc calcTxRoot(transactions: openarray[Transaction]): Hash256 =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in transactions:
    tr.put(rlp.encode(i).toRange, rlp.encode(t).toRange)
  return tr.rootHash

method persistBlocks*(c: Chain, headers: openarray[BlockHeader], bodies: openarray[BlockBody]) =
  # Run the VM here
  assert(headers.len == bodies.len)

  let blockReward = 5.u256 * pow(10.u256, 18) # 5 ETH

  let transaction = c.db.db.beginTransaction()
  defer: transaction.dispose()

  echo "Persisting blocks: ", headers[0].blockNumber, " - ", headers[^1].blockNumber
  for i in 0 ..< headers.len:
    let head = c.db.getCanonicalHead()
    assert(head.blockNumber == headers[i].blockNumber - 1)
    var stateDb = newAccountStateDB(c.db.db, head.stateRoot)
    var gasReward = 0.u256

    assert(bodies[i].transactions.calcTxRoot == headers[i].txRoot)

    if headers[i].txRoot != BLANK_ROOT_HASH:
      # assert(head.blockNumber == headers[i].blockNumber - 1)
      let vmState = newBaseVMState(head, c.db)
      assert(bodies[i].transactions.len != 0)

      if bodies[i].transactions.len != 0:
        echo "block: ", headers[i].blockNumber
        echo "h: ", headers[i].blockHash

        for t in bodies[i].transactions:
          var sender: EthAddress
          if t.getSender(sender):
            gasReward += processTransaction(stateDb, t, sender, head, c.db)
          else:
            assert(false, "Could not get sender")

    var mainReward = blockReward + gasReward
    #echo "mainReward = ", mainReward , " with blockReward = ", blockReward, " and gasReward = ", gasReward

    if headers[i].ommersHash != EMPTY_UNCLE_HASH:
      let h = c.db.persistUncles(bodies[i].uncles)
      assert(h == headers[i].ommersHash)
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
      echo "Wrong state root in block ", headers[i].blockNumber, ". Expected: ", headers[i].stateRoot, ", Actual: ", stateDb.rootHash, " arrived from ", c.db.getCanonicalHead().stateRoot
    assert(headers[i].stateRoot == stateDb.rootHash)

    discard c.db.persistHeaderToDb(headers[i])
    assert(c.db.getCanonicalHead().blockHash == headers[i].blockHash)

    c.db.persistTransactions(bodies[i].transactions)

  transaction.commit()

