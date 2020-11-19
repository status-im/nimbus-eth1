import ../db/db_chain, eth/common, chronicles, ../vm_state, ../vm_types,
  ../vm/[computation, message], ../vm/interpreter/vm_forks, stint, nimcrypto,
  ../utils, eth/trie/db, ./executor, ../config, ../genesis, ../utils,
  stew/endians2

when not defined(release):
  import ../tracer

type
  # Chain's forks not always equals to EVM's forks
  ChainFork = enum
    Frontier,
    Homestead,
    DAOFork,
    Tangerine,
    Spurious,
    Byzantium,
    Constantinople,
    Petersburg,
    Istanbul,
    MuirGlacier,
    Berlin

  Chain* = ref object of AbstractChainDB
    db: BaseChainDB
    forkIds: array[ChainFork, ForkID]
    blockZeroHash: KeccakHash

func toChainFork(c: ChainConfig, number: BlockNumber): ChainFork =
  if number >= c.berlinBlock: Berlin
  elif number >= c.muirGlacierBlock: MuirGlacier
  elif number >= c.istanbulBlock: Istanbul
  elif number >= c.petersburgBlock: Petersburg
  elif number >= c.constantinopleBlock: Constantinople
  elif number >= c.byzantiumBlock: Byzantium
  elif number >= c.eip158Block: Spurious
  elif number >= c.eip150Block: Tangerine
  elif number >= c.daoForkBlock: DAOFork
  elif number >= c.homesteadBlock: Homestead
  else: Frontier

func toNextFork(n: BlockNumber): uint64 =
  if n == high(BlockNumber):
    result = 0'u64
  else:
    result = n.truncate(uint64)

func getNextFork(c: ChainConfig, fork: ChainFork): uint64 =
  let next: array[ChainFork, uint64] = [
    0'u64,
    toNextFork(c.homesteadBlock),
    toNextFork(c.daoForkBlock),
    toNextFork(c.eip150Block),
    toNextFork(c.eip158Block),
    toNextFork(c.byzantiumBlock),
    toNextFork(c.constantinopleBlock),
    toNextFork(c.petersburgBlock),
    toNextFork(c.istanbulBlock),
    toNextFork(c.muirGlacierBlock),
    toNextFork(c.berlinBlock),
  ]

  if fork == high(ChainFork):
    result = 0
    return

  result = next[fork]
  for x in fork..high(ChainFork):
    if result != next[x]:
      result = next[x]
      break

func calculateForkId(c: ChainConfig, fork: ChainFork, prevCRC: uint32, prevFork: uint64): ForkID =
  result.nextFork = c.getNextFork(fork)

  if result.nextFork != prevFork:
    result.crc = crc32(prevCRC, toBytesBE(prevFork))
  else:
    result.crc = prevCRC

func calculateForkIds(c: ChainConfig, genesisCRC: uint32): array[ChainFork, ForkID] =
  var prevCRC = genesisCRC
  var prevFork = c.getNextFork(Frontier)

  for fork in ChainFork:
    result[fork] = calculateForkId(c, fork, prevCRC, prevFork)
    prevFork = result[fork].nextFork
    prevCRC = result[fork].crc

proc newChain*(db: BaseChainDB): Chain =
  result.new
  result.db = db

  if not db.config.daoForkSupport:
    db.config.daoForkBlock = db.config.homesteadBlock
  let chainId = PublicNetwork(db.config.chainId)
  let g = defaultGenesisBlockForNetwork(chainId)
  result.blockZeroHash = g.toBlock.blockHash
  let genesisCRC = crc32(0, result.blockZeroHash.data)
  result.forkIds = calculateForkIds(db.config, genesisCRC)

method genesisHash*(c: Chain): KeccakHash {.gcsafe.} =
  c.blockZeroHash

method getBlockHeader*(c: Chain, b: HashOrNum, output: var BlockHeader): bool {.gcsafe.} =
  case b.isHash
  of true:
    c.db.getBlockHeader(b.hash, output)
  else:
    c.db.getBlockHeader(b.number, output)

method getBestBlockHeader*(c: Chain): BlockHeader {.gcsafe.} =
  c.db.getCanonicalHead()

method getSuccessorHeader*(c: Chain, h: BlockHeader, output: var BlockHeader, skip = 0'u): bool {.gcsafe.} =
  let offset = 1 + skip.toBlockNumber
  if h.blockNumber <= (not 0.toBlockNumber) - offset:
    result = c.db.getBlockHeader(h.blockNumber + offset, output)

method getAncestorHeader*(c: Chain, h: BlockHeader, output: var BlockHeader, skip = 0'u): bool {.gcsafe.} =
  let offset = 1 + skip.toBlockNumber
  if h.blockNumber >= offset:
    result = c.db.getBlockHeader(h.blockNumber - offset, output)

method getBlockBody*(c: Chain, blockHash: KeccakHash): BlockBodyRef =
  result = nil

method persistBlocks*(c: Chain, headers: openarray[BlockHeader], bodies: openarray[BlockBody]): ValidationResult {.gcsafe.} =
  # Run the VM here
  if headers.len != bodies.len:
    debug "Number of headers not matching number of bodies"
    return ValidationResult.Error

  c.db.highestBlock = headers[^1].blockNumber
  let transaction = c.db.db.beginTransaction()
  defer: transaction.dispose()

  trace "Persisting blocks", fromBlock = headers[0].blockNumber, toBlock = headers[^1].blockNumber
  for i in 0 ..< headers.len:
    let head = c.db.getCanonicalHead()
    let vmState = newBaseVMState(head.stateRoot, headers[i], c.db)
    let validationResult = processBlock(c.db, headers[i], bodies[i], vmState)

    when not defined(release):
      if validationResult == ValidationResult.Error and
          bodies[i].transactions.calcTxRoot == headers[i].txRoot:
        dumpDebuggingMetaData(c.db, headers[i], bodies[i], vmState)
        warn "Validation error. Debugging metadata dumped."

    if validationResult != ValidationResult.OK:
      return validationResult

    discard c.db.persistHeaderToDb(headers[i])
    if c.db.getCanonicalHead().blockHash != headers[i].blockHash:
      debug "Stored block header hash doesn't match declared hash"
      return ValidationResult.Error

    discard c.db.persistTransactions(headers[i].blockNumber, bodies[i].transactions)
    discard c.db.persistReceipts(vmState.receipts)

    # update currentBlock *after* we persist it
    # so the rpc return consistent result
    # between eth_blockNumber and eth_syncing
    c.db.currentBlock = headers[i].blockNumber

  transaction.commit()

method getTrieDB*(c: Chain): TrieDatabaseRef {.gcsafe.} =
  c.db.db

method getForkId*(c: Chain, n: BlockNumber): ForkID {.gcsafe.} =
  # EIP 2364/2124
  let fork = c.db.config.toChainFork(n)
  c.forkIds[fork]
