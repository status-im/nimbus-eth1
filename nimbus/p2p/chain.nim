import ../db/[db_chain, state_db], eth_common, chronicles, ../vm_state, ../vm_types, ../transaction, ranges,
  ../vm/[computation, interpreter_dispatch, message, interpreter/vm_forks], ../constants, stint, nimcrypto,
  ../vm_state_transactions, sugar, ../utils, eth_trie/db, ../tracer, ./executor, json,
  eth_bloom, strutils

type
  # TODO: these types need to be removed
  # once eth_bloom and eth_common sync'ed
  Bloom = eth_common.BloomFilter
  LogsBloom = eth_bloom.BloomFilter

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

proc makeReceipt(vmState: BaseVMState, stateRoot: Hash256, cumulativeGasUsed: GasInt, fork = FkFrontier): Receipt =
  if fork < FkByzantium:
    # TODO: which one: vmState.blockHeader.stateRoot or stateDb.rootHash?
    # currently, vmState.blockHeader.stateRoot vs stateDb.rootHash can be different
    # need to wait #188 solved
    result.stateRootOrStatus = hashOrStatus(stateRoot)
  else:
    # TODO: post byzantium fork use status instead of rootHash
    let vmStatus = true # success or failure
    result.stateRootOrStatus = hashOrStatus(vmStatus)

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
    let vmState = if headers[i].txRoot != BLANK_ROOT_HASH: newBaseVMState(head, c.db)
                  else: nil
    let success = processBlock(c.db, head, headers[i], bodies[i], vmState)

    if not success:
      # TODO: move this back into tracer.nim and produce a nice bundle of
      # debugging tool metadata
      let ttrace = traceTransaction(c.db, headers[i], bodies[i], bodies[i].transactions.len - 1, {})
      trace "NIMBUS TRACE", transactionTrace=ttrace.pretty()
      let dump = dumpBlockState(c.db, headers[i], bodies[i])
      trace "NIMBUS STATE DUMP", dump=dump.pretty()

    assert(success)

    discard c.db.persistHeaderToDb(headers[i])
    if c.db.getCanonicalHead().blockHash != headers[i].blockHash:
      debug "Stored block header hash doesn't match declared hash"
      return ValidationResult.Error

    c.db.persistTransactions(headers[i].blockNumber, bodies[i].transactions)
    c.db.persistReceipts(receipts)

  transaction.commit()
