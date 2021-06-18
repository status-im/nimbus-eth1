import
  ../chain_config,
  ../db/db_chain,
  ../genesis,
  ../utils,
  ../vm_state,
  ./executor,
  ./validate,
  ./validate/epoch_hash_cache,
  chronicles,
  eth/[common, trie/db],
  nimcrypto,
  stew/endians2,
  stint

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
    cacheByEpoch: EpochHashCache
    extraValidation: bool

  CanonicalState = object    ## temporary state cache
    canoHead: BlockHeader    ## current canonical head
    restoreHead: BlockHeader ## restore value
    sibling: BlockHeader     ## block number reference of which to be replaced
    needRestoreOk: bool      ## need to restore canonical head


proc updateCanonicalHead(c: Chain; header: BlockHeader;
                         forceUpdateOk: bool): CanonicalState {.inline.} =
  ## If enabled via `forceUpdateOk` the canonical head is moved to the
  ## parent of the argument header and the previous state is captured so
  ## it can be restored.
  result.canoHead = c.db.getCanonicalHead()
  if forceUpdateOk:
    let
      canoNumber = result.canoHead.blockNumber
      canoHash = result.canoHead.hash
      thisNumber = header.blockNumber
      parentHash = header.parentHash

    # Check whether there is something to do, at all
    if forceUpdateOk and parentHash != canoHash and thisNumber <= canoNumber:
      # Set new caconical head and provide restore information.
      result.restoreHead = result.canoHead
      result.canoHead = c.db.getBlockHeader(parentHash)
      c.db.setHead(result.canoHead)

      # Restore original header only if
      #  * the restored chain would be the lingest (i.e. the bock number
      #    of the restored head will be unique maximum number)
      #  * or the sibling header on the to be restored chain, shadowed by the
      #     argument header has higher difficulty.
      result.sibling = c.db.getBlockHeader(thisNumber)
      if thisNumber < canoNumber or
         header.difficulty < result.sibling.difficulty:
        result.needRestoreOk = true


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

proc newChain*(db: BaseChainDB, extraValidation = false): Chain =
  result.new
  result.db = db

  if not db.config.daoForkSupport:
    db.config.daoForkBlock = db.config.homesteadBlock
  let g = defaultGenesisBlockForNetwork(db.networkId)
  result.blockZeroHash = g.toBlock.blockHash
  let genesisCRC = crc32(0, result.blockZeroHash.data)
  result.forkIds = calculateForkIds(db.config, genesisCRC)
  result.extraValidation = extraValidation

  if extraValidation:
    result.cacheByEpoch.initEpochHashCache

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

method persistBlocks*(c: Chain; headers: openarray[BlockHeader];
                      bodies: openarray[BlockBody];
                      forceCanonicalParent = true):
                        ValidationResult {.gcsafe,base.} =
  # Run the VM here
  if headers.len != bodies.len:
    debug "Number of headers not matching number of bodies"
    return ValidationResult.Error

  c.db.highestBlock = headers[^1].blockNumber
  let transaction = c.db.db.beginTransaction()
  defer: transaction.dispose()

  trace "Persisting blocks",
    fromBlock = headers[0].blockNumber,
    toBlock = headers[^1].blockNumber

  for i in 0 ..< headers.len:
    let
      canoState = c.updateCanonicalHead(headers[i], forceCanonicalParent)
      vmState = newBaseVMState(canoState.canoHead.stateRoot, headers[i], c.db)
      validationResult = processBlock(c.db, headers[i], bodies[i], vmState)

    when not defined(release):
      if validationResult == ValidationResult.Error and
          bodies[i].transactions.calcTxRoot == headers[i].txRoot:
        dumpDebuggingMetaData(c.db, headers[i], bodies[i], vmState)
        warn "Validation error. Debugging metadata dumped."

    if validationResult != ValidationResult.OK:
      return validationResult

    if c.extraValidation:
      let res = validateKinship(
        c.db, headers[i],
        bodies[i].uncles,
        checkSealOK = false, # TODO: how to checkseal from here
        c.cacheByEpoch
      )
      if res.isErr:
        debug "kinship validation error", msg = res.error
        return ValidationResult.Error

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

    # Reset canonical head (if requested)
    if canoState.needRestoreOk:
      # The follong command would restore the block number reference to the
      # original header which is now shadowed by the argument header. At least
      # for the tests, this maked no difference so it is omitted.
      #
      # c.db.addBlockNumberToHashLookup(canoState.sibling)
      c.db.setHead(canoState.restoreHead)

  transaction.commit()

method getTrieDB*(c: Chain): TrieDatabaseRef {.gcsafe.} =
  c.db.db

method getForkId*(c: Chain, n: BlockNumber): ForkID {.gcsafe.} =
  # EIP 2364/2124
  let fork = c.db.config.toChainFork(n)
  c.forkIds[fork]
