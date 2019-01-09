import ../db/[db_chain, state_db], eth_common, chronicles, ../vm_state, ../vm_types, ../transaction, ranges,
  ../vm/[computation, interpreter_dispatch, message], ../constants, stint, nimcrypto,
  ../vm_state_transactions, sugar, ../utils, eth_trie/db, ../tracer, ./executor

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

method persistBlocks*(c: Chain, headers: openarray[BlockHeader], bodies: openarray[BlockBody]): ValidationResult =
  # Run the VM here
  if headers.len != bodies.len:
    debug "Number of headers not matching number of bodies"
    return ValidationResult.Error

  let transaction = c.db.db.beginTransaction()
  defer: transaction.dispose()

  trace "Persisting blocks", fromBlock = headers[0].blockNumber, toBlock = headers[^1].blockNumber
  for i in 0 ..< headers.len:
    let head = c.db.getCanonicalHead()
    let vmState = newBaseVMState(head, c.db)
    let validationResult = processBlock(c.db, head, headers[i], bodies[i], vmState)

    when not defined(release) and not defined(debugging_tool):
      if validationResult == ValidationResult.Error:
        dumpDebuggingMetaData(c.db, headers[i], bodies[i], vmState.receipts)

    if validationResult != ValidationResult.OK:
      result = validationResult
      return

    discard c.db.persistHeaderToDb(headers[i])
    if c.db.getCanonicalHead().blockHash != headers[i].blockHash:
      debug "Stored block header hash doesn't match declared hash"
      return ValidationResult.Error

    c.db.persistTransactions(headers[i].blockNumber, bodies[i].transactions)
    c.db.persistReceipts(vmState.receipts)

  transaction.commit()
