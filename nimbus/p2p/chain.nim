import ../db/[db_chain, state_db], eth_common, chronicles, ../vm_state, ../vm_types, ../transaction, ranges,
  ../vm/[computation, interpreter_dispatch, message], ../constants, stint, nimcrypto,
  ../vm_state_transactions, sugar, ../utils, eth_trie/db, ../tracer, ./executor, json,
  eth_bloom, strutils

type
  # these types need to eradicated
  # once eth_bloom and eth_common sync'ed
  Bloom = eth_common.BloomFilter
  LogsBloom = eth_bloom.BloomFilter

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

proc makeReceipt(vmState: BaseVMState, stateRoot: Hash256, cumulativeGasUsed: GasInt): Receipt =
  # TODO: post byzantium fork use status instead of rootHash
  # currently, vmState.rootHash vs stateDb.rootHash can be different
  # need to wait #188 solved
  #result.stateRootOrStatus = hashOrStatus(vmState.blockHeader.stateRoot)
  result.stateRootOrStatus = hashOrStatus(stateRoot)
  result.cumulativeGasUsed = cumulativeGasUsed
  result.logs = vmState.getAndClearLogEntries()
  result.bloom = logsBloom(result.logs).value.toByteArrayBE

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

  debug "Persisting blocks", range = $headers[0].blockNumber & " - " & $headers[^1].blockNumber
  for i in 0 ..< headers.len:
    let head = c.db.getCanonicalHead()
    assert(head.blockNumber == headers[i].blockNumber - 1)
    var stateDb = newAccountStateDB(c.db.db, head.stateRoot, c.db.pruneTrie)
    var receipts = newSeq[Receipt](bodies[i].transactions.len)

    assert(bodies[i].transactions.calcTxRoot == headers[i].txRoot)

    if headers[i].txRoot != BLANK_ROOT_HASH:
      assert(head.blockNumber == headers[i].blockNumber - 1)
      let vmState = newBaseVMState(head, c.db)
      assert(bodies[i].transactions.len != 0)
      var cumulativeGasUsed = GasInt(0)

      if bodies[i].transactions.len != 0:
        trace "Has transactions", blockNumber = headers[i].blockNumber, blockHash = headers[i].blockHash

        for txIndex, tx in bodies[i].transactions:
          var sender: EthAddress
          if tx.getSender(sender):
            let txFee = processTransaction(stateDb, tx, sender, vmState)

            # perhaps this can be moved somewhere else
            let gasUsed = (txFee div tx.gasPrice.u256).truncate(GasInt)
            cumulativeGasUsed += gasUsed

            # miner fee
            stateDb.addBalance(headers[i].coinbase, txFee)
          else:
            assert(false, "Could not get sender")
          receipts[txIndex] = makeReceipt(vmState, stateDb.rootHash, cumulativeGasUsed)

    var mainReward = blockReward
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

    let bloom = createBloom(receipts)
    if headers[i].bloom != bloom:
      debug "wrong bloom in block", blockNumber = headers[i].blockNumber
    assert(headers[i].bloom == bloom)

    let receiptRoot = calcReceiptRoot(receipts)
    if headers[i].receiptRoot != receiptRoot:
      debug "wrong receipt in block", blockNumber = headers[i].blockNumber, receiptRoot, valid=headers[i].receiptRoot
    assert(headers[i].receiptRoot == receiptRoot)

    discard c.db.persistHeaderToDb(headers[i])
    assert(c.db.getCanonicalHead().blockHash == headers[i].blockHash)

    c.db.persistTransactions(headers[i].blockNumber, bodies[i].transactions)
    c.db.persistReceipts(receipts)

  transaction.commit()
