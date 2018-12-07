import ../db/[db_chain, state_db], eth_common, chronicles, ../vm_state, ../vm_types, ../transaction, ranges,
  ../vm/[computation, interpreter_dispatch, message], ../constants, stint, nimcrypto,
  ../vm_state_transactions, sugar, ../utils, eth_trie/db, ../tracer, ./executor, json

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

method persistBlocks*(c: Chain, headers: openarray[BlockHeader], bodies: openarray[BlockBody]) =
  # Run the VM here
  assert(headers.len == bodies.len)

  let blockReward = 5.u256 * pow(10.u256, 18) # 5 ETH

  let transaction = c.db.db.beginTransaction()
  defer: transaction.dispose()

  trace "Persisting blocks", range = headers[0].blockNumber & " - " & headers[^1].blockNumber
  for i in 0 ..< headers.len:
    let head = c.db.getCanonicalHead()
    assert(head.blockNumber == headers[i].blockNumber - 1)
    var gasReward = 0.u256

    assert(bodies[i].transactions.calcTxRoot == headers[i].txRoot)
    let vmState = newBaseVMState(head, c.db)
    
    if headers[i].txRoot != BLANK_ROOT_HASH:
      # assert(head.blockNumber == headers[i].blockNumber - 1)      
      assert(bodies[i].transactions.len != 0)

      if bodies[i].transactions.len != 0:
        trace "Has transactions", blockNumber = headers[i].blockNumber, blockHash = headers[i].blockHash

        for t in bodies[i].transactions:
          var sender: EthAddress
          if t.getSender(sender):
            gasReward += processTransaction(t, sender, vmState)
          else:
            assert(false, "Could not get sender")

    var mainReward = blockReward + gasReward
    #echo "mainReward = ", mainReward , " with blockReward = ", blockReward, " and gasReward = ", gasReward

    var stateDB = vmState.mutableStateDB()
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
      debug "Wrong state root in block", blockNumber = headers[i].blockNumber, expected = headers[i].stateRoot, actual = stateDb.rootHash, arrivedFrom = c.db.getCanonicalHead().stateRoot
      let ttrace = traceTransaction(c.db, headers[i], bodies[i], bodies[i].transactions.len - 1, {})
      trace "NIMBUS TRACE", transactionTrace=ttrace.pretty()

    assert(headers[i].stateRoot == stateDb.rootHash)

    discard c.db.persistHeaderToDb(headers[i])
    assert(c.db.getCanonicalHead().blockHash == headers[i].blockHash)

    c.db.persistTransactions(headers[i].blockNumber, bodies[i].transactions)

  transaction.commit()

