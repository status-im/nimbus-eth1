import ../db/[db_chain, state_db], eth_common, chronicles, ../vm_state, ../vm_types, ../transaction, ranges,
  ../vm/[computation, interpreter_dispatch, message], ../constants


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

  for i in 0 ..< headers.len:
    echo "Persisting block: ", headers[i].blockNumber
    if headers[i].txRoot != BLANK_ROOT_HASH:
      let head = c.db.getCanonicalHead()
      # assert(head.blockNumber == headers[i].blockNumber - 1)
      let vmState = newBaseVMState(head, c.db)
      let stateDb = newAccountStateDB(c.db.db, head.stateRoot)
      if bodies[i].transactions.len != 0:
        # echo "block: ", headers[i].blockNumber
        for t in bodies[i].transactions:
          var sender: EthAddress
          if t.getSender(sender):
            echo "Sender: ", sender
            let code = stateDb.getCode(sender)
            debug "Transaction", sender, to = t.to, value = t.value, hasCode = code.len != 0
            let msg = newMessage(t.gasLimit, t.gasPrice, t.to, sender, t.value, t.payload, code.toSeq)
      assert(false, "Dont know how to persist transactions")

    if headers[i].ommersHash != EMPTY_UNCLE_HASH:
      debug "Ignoring ommers", blockNumber = headers[i].blockNumber
      
    discard c.db.persistHeaderToDb(headers[i])
    assert(c.db.getCanonicalHead().blockHash == headers[i].blockHash)


  discard
