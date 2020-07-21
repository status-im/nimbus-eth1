# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, json, os, tables, strutils, sets, strformat, times,
  options,
  eth/[common, rlp], eth/trie/[db, trie_defs],
  ethash, stew/endians2, nimcrypto,
  ./test_helpers, ./test_allowed_to_fail,
  ../premix/parser, test_config,
  ../nimbus/vm/interpreter/vm_forks,
  ../nimbus/[vm_state, utils, vm_types, errors, transaction, constants],
  ../nimbus/db/[db_chain, accounts_cache],
  ../nimbus/utils/header,
  ../nimbus/p2p/[executor, dao],
  ../nimbus/config,
  ../stateless/[tree_from_witness, witness_types]

type
  SealEngine = enum
    NoProof
    Ethash

  VMConfig = array[2, tuple[blockNumber: int, fork: Fork]]

  PlainBlock = object
    header: BlockHeader
    transactions: seq[Transaction]
    uncles: seq[BlockHeader]

  TesterBlock = object
    blockHeader: Option[BlockHeader]
    transactions: seq[Transaction]
    uncles: seq[BlockHeader]
    blockNumber: Option[int]
    chainName: Option[string]
    chainNetwork: Option[Fork]
    exceptions: seq[(string, string)]
    headerRLP: Blob

  Tester = object
    lastBlockHash: Hash256
    genesisBlockHeader: BlockHeader
    blocks: seq[TesterBlock]
    sealEngine: Option[SealEngine]
    vmConfig: VMConfig
    good: bool
    debugMode: bool
    trace: bool
    vmState: BaseVMState
    debugData: JsonNode
    network: string

  MiningHeader* = object
    parentHash*:    Hash256
    ommersHash*:    Hash256
    coinbase*:      EthAddress
    stateRoot*:     Hash256
    txRoot*:        Hash256
    receiptRoot*:   Hash256
    bloom*:         common.BloomFilter
    difficulty*:    DifficultyInt
    blockNumber*:   BlockNumber
    gasLimit*:      GasInt
    gasUsed*:       GasInt
    timestamp*:     EthTime
    extraData*:     Blob

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus, debugMode = false, trace = false)

func normalizeNumber(n: JsonNode): JsonNode =
  let str = n.getStr
  # paranoid checks
  doAssert n.kind == Jstring
  doAssert str[0] == '0' and str[1] == 'x'
  # real normalization
  # strip leading 0
  if str == "0x":
    result = newJString("0x0")
  elif str == "0x0":
    result = n
  elif str == "0x00":
    result = newJString("0x0")
  elif str[2] == '0':
    var i =  2
    while str[i] == '0':
      inc i
    result = newJString("0x" & str.substr(i))
  else:
    result = n

func normalizeData(n: JsonNode): JsonNode =
  if n.getStr() == "":
    result = newJString("0x")
  else:
    result = n

func normalizeBlockHeader(node: JsonNode): JsonNode =
  for k, v in node:
    case k
    of "bloom": node["logsBloom"] = v
    of "coinbase": node["miner"] = v
    of "uncleHash": node["sha3Uncles"] = v
    of "receiptTrie": node["receiptsRoot"] = v
    of "transactionsTrie": node["transactionsRoot"] = v
    of "number", "difficulty", "gasUsed",
      "gasLimit", "timestamp":
        node[k] = normalizeNumber(v)
    of "extraData":
      node[k] = normalizeData(v)
    else: discard
  result = node

proc parseHeader(blockHeader: JsonNode, testStatusIMPL: var TestStatus): BlockHeader =
  result = normalizeBlockHeader(blockHeader).parseBlockHeader
  var blockHash: Hash256
  blockHeader.fromJson "hash", blockHash
  check blockHash == hash(result)

proc parseTx*(n: JsonNode): Transaction =

  for k, v in n:
    case k
    of "nonce", "gasPrice", "gasLimit", "value":
      n[k] = normalizeNumber(v)
    of "to":
      let str = v.getStr
      if str.len > 2 and str[1] != 'x':
        n[k] = newJString("0x" & str)
    of "v", "r", "s":
      n[k] = normalizeNumber(v)
    else:
      discard

  n.fromJson "nonce", result.accountNonce
  n.fromJson "gasPrice", result.gasPrice
  n.fromJson "gasLimit", result.gasLimit
  result.isContractCreation = n["to"].getStr == ""
  if not result.isContractCreation:
    n.fromJson "to", result.to
  n.fromJson "value", result.value
  n.fromJson "data", result.payload
  n.fromJson "v", result.V
  n.fromJson "r", result.R
  n.fromJson "s", result.S

proc parseBlocks(blocks: JsonNode, testStatusIMPL: var TestStatus): seq[TesterBlock] =
  result = @[]

  for fixture in blocks:
    var t: TesterBlock
    for key, value in fixture:
      case key
      of "blockHeader":
        t.blockHeader = some(parseHeader(fixture["blockHeader"], testStatusIMPL))
      of "blocknumber":
        let numberStr = value.getStr
        if numberStr.len >= 2 and numberStr[1] == 'x':
          fixture[key] = normalizeNumber(value)
          var number: int
          fixture.fromJson "blocknumber", number
          t.blockNumber = some(number)
        else:
          t.blockNumber = some(parseInt(numberStr))
      of "chainname":
        t.chainName = some(value.getStr)
      of "chainnetwork":
        t.chainNetWork = some(parseEnum[Fork](value.getStr))
      of "rlp":
        fixture.fromJson "rlp", t.headerRLP
      of "transactions":
        for tx in value:
          t.transactions.add parseTx(tx)
      of "uncleHeaders":
        t.uncles = @[]
        for uncle in value:
          t.uncles.add parseHeader(uncle, testStatusIMPL)
      else:
        t.exceptions.add( (key, value.getStr) )

    if t.blockHeader.isSome:
      let h = t.blockHeader.get()
      check calcTxRoot(t.transactions) == h.txRoot
      let enc = rlp.encode(t.uncles)
      check keccakHash(enc) == h.ommersHash

    result.add t

func vmConfiguration(network: string, c: var ChainConfig): VMConfig =

  c.homesteadBlock = high(BlockNumber)
  c.daoForkBlock = high(BlockNumber)
  c.daoForkSupport = false
  c.eip150Block = high(BlockNumber)
  c.eip158Block = high(BlockNumber)
  c.byzantiumBlock = high(BlockNumber)
  c.constantinopleBlock = high(BlockNumber)
  c.petersburgBlock = high(BlockNumber)
  c.istanbulBlock = high(BlockNumber)
  c.muirGlacierBlock = high(BlockNumber)

  case network
  of "EIP150":
    result = [(0, FkTangerine), (0, FkTangerine)]
    c.eip150Block = 0.toBlockNumber
  of "ConstantinopleFix":
    result = [(0, FkPetersburg), (0, FkPetersburg)]
    c.petersburgBlock = 0.toBlockNumber
  of "Homestead":
    result = [(0, FkHomestead), (0, FkHomestead)]
    c.homesteadBlock = 0.toBlockNumber
  of "Frontier":
    result = [(0, FkFrontier), (0, FkFrontier)]
    #c.frontierBlock = 0.toBlockNumber
  of "Byzantium":
    result = [(0, FkByzantium), (0, FkByzantium)]
    c.byzantiumBlock = 0.toBlockNumber
  of "EIP158ToByzantiumAt5":
    result = [(0, FkSpurious), (5, FkByzantium)]
    c.eip158Block = 0.toBlockNumber
    c.byzantiumBlock = 5.toBlockNumber
  of "EIP158":
    result = [(0, FkSpurious), (0, FkSpurious)]
    c.eip158Block = 0.toBlockNumber
  of "HomesteadToDaoAt5":
    result = [(0, FkHomestead), (5, FkHomestead)]
    c.homesteadBlock = 0.toBlockNumber
    c.daoForkBlock = 5.toBlockNumber
    c.daoForkSupport = true
  of "Constantinople":
    result = [(0, FkConstantinople), (0, FkConstantinople)]
    c.constantinopleBlock = 0.toBlockNumber
  of "HomesteadToEIP150At5":
    result = [(0, FkHomestead), (5, FkTangerine)]
    c.homesteadBlock = 0.toBlockNumber
    c.eip150Block = 5.toBlockNumber
  of "FrontierToHomesteadAt5":
    result = [(0, FkFrontier), (5, FkHomestead)]
    #c.frontierBlock = 0.toBlockNumber
    c.homesteadBlock = 5.toBlockNumber
  of "ByzantiumToConstantinopleFixAt5":
    result = [(0, FkByzantium), (5, FkPetersburg)]
    c.byzantiumBlock = 0.toBlockNumber
    c.petersburgBlock = 5.toBlockNumber
  of "Istanbul":
    result = [(0, FkIstanbul), (0, FkIstanbul)]
    c.istanbulBlock = 0.toBlockNumber
  else:
    raise newException(ValueError, "unsupported network")

func vmConfigToFork(vmConfig: VMConfig, blockNumber: Uint256): Fork =
  if blockNumber >= vmConfig[1].blockNumber.u256: return vmConfig[1].fork
  if blockNumber >= vmConfig[0].blockNumber.u256: return vmConfig[0].fork
  raise newException(ValueError, "unreachable code")

proc parseTester(fixture: JsonNode, testStatusIMPL: var TestStatus): Tester =
  result.good = true
  fixture.fromJson "lastblockhash", result.lastBlockHash
  result.genesisBlockHeader = parseHeader(fixture["genesisBlockHeader"], testStatusIMPL)

  if "genesisRLP" in fixture:
    var genesisRLP: Blob
    fixture.fromJson "genesisRLP", genesisRLP
    let genesisBlock = PlainBlock(header: result.genesisBlockHeader)
    check genesisRLP == rlp.encode(genesisBlock)

  if "sealEngine" in fixture:
    result.sealEngine = some(parseEnum[SealEngine](fixture["sealEngine"].getStr))
  result.network = fixture["network"].getStr

  try:
    result.blocks = parseBlocks(fixture["blocks"], testStatusIMPL)
  except ValueError:
    result.good = false

  # TODO: implement missing VM
  #if result.network in ["HomesteadToDaoAt5"]:
    #result.good = false

proc blockWitness(vmState: BaseVMState, fork: Fork, chainDB: BaseChainDB) =
  let rootHash = vmState.accountDb.rootHash
  let witness = vmState.buildWitness()
  let flags = if fork >= FKSpurious: {wfEIP170} else: {}

  # build tree from witness
  var db = newMemoryDB()
  when defined(useInputStream):
    var input = memoryInput(witness)
    var tb = initTreeBuilder(input, db, flags)
  else:
    var tb = initTreeBuilder(witness, db, flags)
  let root = tb.buildTree()

  # compare the result
  if root != rootHash:
    raise newException(ValidationError, "Invalid trie generated from block witness")

proc assignBlockRewards(minedBlock: PlainBlock, vmState: BaseVMState, fork: Fork, chainDB: BaseChainDB) =
  let blockReward = blockRewards[fork]
  var mainReward = blockReward
  if minedBlock.header.ommersHash != EMPTY_UNCLE_HASH:
    let h = vmState.chainDB.persistUncles(minedBlock.uncles)
    if h != minedBlock.header.ommersHash:
      raise newException(ValidationError, "Uncle hash mismatch")
    for uncle in minedBlock.uncles:
      var uncleReward = uncle.blockNumber.u256 + 8.u256
      uncleReward -= minedBlock.header.blockNumber.u256
      uncleReward = uncleReward * blockReward
      uncleReward = uncleReward div 8.u256
      vmState.mutateStateDB:
        db.addBalance(uncle.coinbase, uncleReward)
      mainReward += blockReward div 32.u256

  # Reward beneficiary
  vmState.mutateStateDB:
    db.addBalance(minedBlock.header.coinbase, mainReward)
    if vmState.generateWitness:
      db.collectWitnessData()
    db.persist()

  let stateDb = vmState.accountDb
  if minedBlock.header.stateRoot != stateDb.rootHash:
    raise newException(ValidationError, "wrong state root in block")

  let bloom = createBloom(vmState.receipts)
  if minedBlock.header.bloom != bloom:
    raise newException(ValidationError, "wrong bloom")

  let receiptRoot = calcReceiptRoot(vmState.receipts)
  if minedBlock.header.receiptRoot != receiptRoot:
    raise newException(ValidationError, "wrong receiptRoot")

  let txRoot = calcTxRoot(minedBlock.transactions)
  if minedBlock.header.txRoot != txRoot:
    raise newException(ValidationError, "wrong txRoot")

  if vmState.generateWitness:
    blockWitness(vmState, fork, chainDB)

proc processBlock(chainDB: BaseChainDB, vmState: BaseVMState, minedBlock: PlainBlock, fork: Fork) =
  var dbTx = chainDB.db.beginTransaction()
  defer: dbTx.dispose()

  if chainDB.config.daoForkSupport and minedBlock.header.blockNumber == chainDB.config.daoForkBlock:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  vmState.receipts = newSeq[Receipt](minedBlock.transactions.len)
  vmState.cumulativeGasUsed = 0

  for txIndex, tx in minedBlock.transactions:
    var sender: EthAddress
    if tx.getSender(sender):
      discard processTransaction(tx, sender, vmState, fork)
    else:
      raise newException(ValidationError, "could not get sender")
    vmState.receipts[txIndex] = makeReceipt(vmState, fork)

  if vmState.cumulativeGasUsed != minedBlock.header.gasUsed:
    raise newException(ValidationError, &"wrong gas used in header expected={minedBlock.header.gasUsed}, actual={vmState.cumulativeGasUsed}")

  assignBlockRewards(minedBlock, vmState, fork, vmState.chainDB)

  # `applyDeletes = false`
  # preserve previous block stateRoot
  # while still benefits from trie pruning
  dbTx.commit(applyDeletes = false)

func validateBlockUnchanged(a, b: PlainBlock): bool =
  result = rlp.encode(a) == rlp.encode(b)

type Hash512 = MDigest[512]
var cacheByEpoch = initOrderedTable[uint64, seq[Hash512]]()
const CACHE_MAX_ITEMS = 10

proc mkCacheBytes(blockNumber: uint64): seq[Hash512] =
  mkcache(getCacheSize(blockNumber), getSeedhash(blockNumber))

proc getCache(blockNumber: uint64): seq[Hash512] =
  # TODO: this is very inefficient
  let epochIndex = blockNumber div EPOCH_LENGTH

  # Get the cache if already generated, marking it as recently used
  if epochIndex in cacheByEpoch:
    let c = cacheByEpoch[epochIndex]
    cacheByEpoch.del(epochIndex)  # pop and append at end
    cacheByEpoch[epochIndex] = c
    return c

  # Generate the cache if it was not already in memory
  # Simulate requesting mkcache by block number: multiply index by epoch length
  let c = mkCacheBytes(epochIndex * EPOCH_LENGTH)
  cacheByEpoch[epochIndex] = c

  # Limit memory usage for cache
  if cacheByEpoch.len > CACHE_MAX_ITEMS:
    cacheByEpoch.del(epochIndex)

  shallowCopy(result, c)

func cacheHash(x: openArray[Hash512]): Hash256 =
  var ctx: keccak256
  ctx.init()

  for a in x:
    ctx.update(a.data[0].unsafeAddr, uint(a.data.len))

  ctx.finish result.data
  ctx.clear()

proc checkPOW(blockNumber: Uint256, miningHash, mixHash: Hash256, nonce: BlockNonce, difficulty: DifficultyInt) =
  let blockNumber = blockNumber.truncate(uint64)
  let cache = blockNumber.getCache()

  let size = getDataSize(blockNumber)
  let miningOutput = hashimotoLight(size, cache, miningHash, uint64.fromBytesBE(nonce))
  if miningOutput.mixDigest != mixHash:
    echo "actual: ", miningOutput.mixDigest
    echo "expected: ", mixHash
    echo "blockNumber: ", blockNumber
    echo "miningHash: ", miningHash
    echo "nonce: ", nonce.toHex
    echo "difficulty: ", difficulty
    echo "size: ", size
    echo "cache hash: ", cacheHash(cache)
    raise newException(ValidationError, "mixHash mismatch")

  let value = Uint256.fromBytesBE(miningOutput.value.data)
  if value > Uint256.high div difficulty:
    raise newException(ValidationError, "mining difficulty error")

func toMiningHeader(header: BlockHeader): MiningHeader =
  result.parentHash  = header.parentHash
  result.ommersHash  = header.ommersHash
  result.coinbase    = header.coinbase
  result.stateRoot   = header.stateRoot
  result.txRoot      = header.txRoot
  result.receiptRoot = header.receiptRoot
  result.bloom       = header.bloom
  result.difficulty  = header.difficulty
  result.blockNumber = header.blockNumber
  result.gasLimit    = header.gasLimit
  result.gasUsed     = header.gasUsed
  result.timestamp   = header.timestamp
  result.extraData   = header.extraData

func hash(header: MiningHeader): Hash256 =
  keccakHash(rlp.encode(header))

proc validateSeal(header: BlockHeader) =
  let miningHeader = header.toMiningHeader
  let miningHash = miningHeader.hash

  checkPOW(header.blockNumber, miningHash,
           header.mixDigest, header.nonce, header.difficulty)

func validateGasLimit(gasLimit, parentGasLimit: GasInt) =
  if gasLimit < GAS_LIMIT_MINIMUM:
    raise newException(ValidationError, "Gas limit is below minimum")
  if gasLimit > GAS_LIMIT_MAXIMUM:
    raise newException(ValidationError, "Gas limit is above maximum")
  let diff = gasLimit - parentGasLimit
  if diff > (parentGasLimit div GAS_LIMIT_ADJUSTMENT_FACTOR):
    raise newException(ValidationError, "Gas limit difference to parent is too big")

proc validateHeader(header, parentHeader: BlockHeader, checkSeal: bool) =
  if header.extraData.len > 32:
    raise newException(ValidationError, "BlockHeader.extraData larger than 32 bytes")

  validateGasLimit(header.gasLimit, parentHeader.gasLimit)

  if header.blockNumber != parentHeader.blockNumber + 1:
    raise newException(ValidationError, "Blocks must be numbered consecutively.")

  if header.timestamp.toUnix <= parentHeader.timestamp.toUnix:
    raise newException(ValidationError, "timestamp must be strictly later than parent")

  if checkSeal:
    validateSeal(header)

func validateUncle(currBlock, uncle, uncleParent: BlockHeader) =
  if uncle.blockNumber >= currBlock.blockNumber:
    raise newException(ValidationError, "uncle block number larger than current block number")

  if uncle.blockNumber != uncleParent.blockNumber + 1:
    raise newException(ValidationError, "Uncle number is not one above ancestor's number")

  if uncle.timestamp.toUnix < uncleParent.timestamp.toUnix:
    raise newException(ValidationError, "Uncle timestamp is before ancestor's timestamp")

  if uncle.gasUsed > uncle.gasLimit:
    raise newException(ValidationError, "Uncle's gas usage is above the limit")

proc validateGasLimit(chainDB: BaseChainDB, header: BlockHeader) =
  let parentHeader = chainDB.getBlockHeader(header.parentHash)
  let (lowBound, highBound) = gasLimitBounds(parentHeader)

  if header.gasLimit < lowBound:
    raise newException(ValidationError, "The gas limit is too low")
  elif header.gasLimit > highBound:
    raise newException(ValidationError, "The gas limit is too high")

proc validateUncles(chainDB: BaseChainDB, currBlock: PlainBlock, checkSeal: bool) =
  let hasUncles = currBlock.uncles.len > 0
  let shouldHaveUncles = currBlock.header.ommersHash != EMPTY_UNCLE_HASH

  if not hasUncles and not shouldHaveUncles:
    # optimization to avoid loading ancestors from DB, since the block has no uncles
    return
  elif hasUncles and not shouldHaveUncles:
    raise newException(ValidationError, "Block has uncles but header suggests uncles should be empty")
  elif shouldHaveUncles and not hasUncles:
    raise newException(ValidationError, "Header suggests block should have uncles but block has none")

  # Check for duplicates
  var uncleSet = initHashSet[Hash256]()
  for uncle in currBlock.uncles:
    let uncleHash = uncle.hash
    if uncleHash in uncleSet:
      raise newException(ValidationError, "Block contains duplicate uncles")
    else:
      uncleSet.incl uncleHash

  let recentAncestorHashes = chainDB.getAncestorsHashes(MAX_UNCLE_DEPTH + 1, currBlock.header)
  let recentUncleHashes = chainDB.getUncleHashes(recentAncestorHashes)
  let blockHash =currBlock.header.hash

  for uncle in currBlock.uncles:
    let uncleHash = uncle.hash

    if uncleHash == blockHash:
      raise newException(ValidationError, "Uncle has same hash as block")

    # ensure the uncle has not already been included.
    if uncleHash in recentUncleHashes:
      raise newException(ValidationError, "Duplicate uncle")

    # ensure that the uncle is not one of the canonical chain blocks.
    if uncleHash in recentAncestorHashes:
      raise newException(ValidationError, "Uncle cannot be an ancestor")

    # ensure that the uncle was built off of one of the canonical chain
    # blocks.
    if (uncle.parentHash notin recentAncestorHashes) or
       (uncle.parentHash == currBlock.header.parentHash):
      raise newException(ValidationError, "Uncle's parent is not an ancestor")

    # Now perform VM level validation of the uncle
    if checkSeal:
      validateSeal(uncle)

    let uncleParent = chainDB.getBlockHeader(uncle.parentHash)
    validateUncle(currBlock.header, uncle, uncleParent)

func isGenesis(currBlock: PlainBlock): bool =
  result = currBlock.header.blockNumber == 0.u256 and currBlock.header.parentHash == GENESIS_PARENT_HASH

proc validateBlock(chainDB: BaseChainDB, currBlock: PlainBlock, checkSeal: bool): bool =
  if currBlock.isGenesis:
    if currBlock.header.extraData.len > 32:
      raise newException(ValidationError, "BlockHeader.extraData larger than 32 bytes")
    return true

  let parentHeader = chainDB.getBlockHeader(currBlock.header.parentHash)
  validateHeader(currBlock.header, parentHeader, checkSeal)

  if currBlock.uncles.len > MAX_UNCLES:
    raise newException(ValidationError, "Number of uncles exceed limit.")

  if not chainDB.exists(currBlock.header.stateRoot):
    raise newException(ValidationError, "`state_root` was not found in the db.")

  validateUncles(chainDB, currBlock, checkSeal)
  validateGaslimit(chainDB, currBlock.header)

  result = true

proc importBlock(tester: var Tester, chainDB: BaseChainDB,
  preminedBlock: PlainBlock, fork: Fork, checkSeal, validation = true): PlainBlock =

  let parentHeader = chainDB.getBlockHeader(preminedBlock.header.parentHash)
  let baseHeaderForImport = generateHeaderFromParentHeader(chainDB.config,
      parentHeader,
      preminedBlock.header.coinbase,
      some(preminedBlock.header.timestamp),
      some(preminedBlock.header.gasLimit),
      @[]
  )

  deepCopy(result, preminedBlock)
  let tracerFlags: set[TracerFlags] = if tester.trace: {TracerFlags.EnableTracing} else : {}
  tester.vmState = newBaseVMState(parentHeader.stateRoot, baseHeaderForImport, chainDB, tracerFlags)

  processBlock(chainDB, tester.vmState, result, fork)

  result.header.stateRoot = tester.vmState.blockHeader.stateRoot
  result.header.parentHash = parentHeader.hash
  result.header.difficulty = baseHeaderForImport.difficulty

  if validation:
    if not validateBlockUnchanged(result, preminedBlock):
      raise newException(ValidationError, "block changed")
    if not validateBlock(chainDB, result, checkSeal):
      raise newException(ValidationError, "invalid block")

  discard chainDB.persistHeaderToDb(preminedBlock.header)

proc applyFixtureBlockToChain(tester: var Tester, tb: TesterBlock,
  chainDB: BaseChainDB, checkSeal, validation = true): (PlainBlock, PlainBlock, Blob) =

  # we hack the ChainConfig here and let it works with calcDifficulty
  tester.vmConfig = vmConfiguration(tester.network, chainDB.config)

  var
    preminedBlock = rlp.decode(tb.headerRLP, PlainBlock)
    fork = vmConfigToFork(tester.vmConfig, preminedBlock.header.blockNumber)
    minedBlock = tester.importBlock(chainDB, preminedBlock, fork, checkSeal, validation)
    rlpEncodedMinedBlock = rlp.encode(minedBlock)
  result = (preminedBlock, minedBlock, rlpEncodedMinedBlock)

func shouldCheckSeal(tester: Tester): bool =
  if tester.sealEngine.isSome:
    result = tester.sealEngine.get() != NoProof

proc collectDebugData(tester: var Tester) =
  let vmState = tester.vmState
  let tracingResult = if tester.trace: vmState.getTracingResult() else: %[]
  tester.debugData.add %{
    "blockNumber": %($vmState.blockNumber),
    "structLogs": tracingResult,
  }

proc runTester(tester: var Tester, chainDB: BaseChainDB, testStatusIMPL: var TestStatus) =
  discard chainDB.persistHeaderToDb(tester.genesisBlockHeader)
  check chainDB.getCanonicalHead().blockHash == tester.genesisBlockHeader.blockHash
  let checkSeal = tester.shouldCheckSeal

  if tester.debugMode:
    tester.debugData = newJArray()

  for idx, testerBlock in tester.blocks:
    let shouldBeGoodBlock = testerBlock.blockHeader.isSome

    if shouldBeGoodBlock:
      try:
        let (preminedBlock, _, _) = tester.applyFixtureBlockToChain(
            testerBlock, chainDB, checkSeal, validation = false)  # we manually validate below
        check validateBlock(chainDB, preminedBlock, checkSeal) == true
      except:
        debugEcho "FATAL ERROR(WE HAVE BUG): ", getCurrentExceptionMsg()

    else:
      var noError = true
      try:
        let (_, _, _) = tester.applyFixtureBlockToChain(testerBlock,
          chainDB, checkSeal, validation = true)
      except ValueError, ValidationError, BlockNotFound, MalformedRlpError, RlpTypeMismatch:
        # failure is expected on this bad block
        noError = false

      # Block should have caused a validation error
      check noError == false

    if tester.debugMode:
      tester.collectDebugData()

proc dumpAccount(accountDb: ReadOnlyStateDB, address: EthAddress, name: string): JsonNode =
  result = %{
    "name": %name,
    "address": %($address),
    "nonce": %toHex(accountDb.getNonce(address)),
    "balance": %accountDb.getBalance(address).toHex(),
    "codehash": %($accountDb.getCodeHash(address)),
    "storageRoot": %($accountDb.getStorageRoot(address))
  }

proc dumpDebugData(tester: Tester, fixture: JsonNode, fixtureName: string, fixtureIndex: int, success: bool) =
  let accountList = if fixture["postState"].kind == JObject: fixture["postState"] else: fixture["pre"]
  let vmState = tester.vmState
  var accounts = newJObject()
  var i = 0
  for ac, _ in accountList:
    let account = ethAddressFromHex(ac)
    accounts[$account] = dumpAccount(vmState.readOnlyStateDB, account, "acc" & $i)
    inc i

  let debugData = %{
    "debugData": tester.debugData,
    "accounts": accounts
  }

  let status = if success: "_success" else: "_failed"
  writeFile("debug_" & fixtureName & "_" & $fixtureIndex & status & ".json", debugData.pretty())

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus, debugMode = false, trace = false) =
  # 1 - mine the genesis block
  # 2 - loop over blocks:
  #     - apply transactions
  #     - mine block
  # 3 - diff resulting state with expected state
  # 4 - check that all previous blocks were valid
  let specifyIndex = test_config.getConfiguration().index
  var fixtureIndex = 0
  var fixtureTested = false

  for fixtureName, fixture in node:
    inc fixtureIndex
    if specifyIndex > 0 and fixtureIndex != specifyIndex:
      continue

    var tester = parseTester(fixture, testStatusIMPL)
    var chainDB = newBaseChainDB(newMemoryDb(), pruneTrie = test_config.getConfiguration().pruning)

    if not tester.good: continue

    var vmState = newBaseVMState(emptyRlpHash,
      tester.genesisBlockHeader, chainDB)

    vmState.generateWitness = true

    vmState.mutateStateDB:
      setupStateDB(fixture["pre"], db)
      db.persist()

    let obtainedHash = $(vmState.readOnlyStateDB.rootHash)
    check obtainedHash == $(tester.genesisBlockHeader.stateRoot)

    tester.debugMode = debugMode
    tester.trace = trace

    var success = true
    try:
      tester.runTester(chainDB, testStatusIMPL)

      let latestBlockHash = chainDB.getCanonicalHead().blockHash
      if latestBlockHash != tester.lastBlockHash:
        verifyStateDB(fixture["postState"], tester.vmState.readOnlyStateDB)
    except ValidationError as E:
      echo fixtureName, " ERROR: ", E.msg
      success = false

    if tester.debugMode:
      tester.dumpDebugData(fixture, fixtureName, fixtureIndex, success)

    fixtureTested = true
    check success == true

  if not fixtureTested:
    echo test_config.getConfiguration().testSubject, " not tested at all, wrong index?"
    if specifyIndex <= 0 or specifyIndex > node.len:
      echo "Maximum subtest available: ", node.len

proc blockchainJsonMain*(debugMode = false) =
  if paramCount() == 0 or not debugMode:
    # run all test fixtures
    suite "block chain json tests":
      jsonTest("BlockchainTests", testFixture, skipBCTests)
    suite "new block chain json tests":
      jsonTest("newBlockChainTests", testFixture, skipNewBCTests)
  else:
    # execute single test in debug mode
    let config = test_config.getConfiguration()
    if config.testSubject.len == 0:
      echo "missing test subject"
      quit(QuitFailure)

    let folder = if config.legacy: "BlockchainTests" else: "newBlockChainTests"
    let path = "tests" / "fixtures" / folder
    let n = json.parseFile(path / config.testSubject)
    var testStatusIMPL: TestStatus
    testFixture(n, testStatusIMPL, debugMode = true, config.trace)

when isMainModule:
  var message: string

  ## Processing command line arguments
  if test_config.processArguments(message) != test_config.Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  blockchainJsonMain(true)

# lastBlockHash -> every fixture has it, hash of a block header
# genesisRLP -> NOT every fixture has it, rlp bytes of genesis block header
# _info -> every fixture has it, can be omitted
# pre, postState -> every fixture has it, prestate and post state
# genesisBlockHeader -> every fixture has it
# network -> every fixture has it
#   # EIP150 247
#   # ConstantinopleFix 286
#   # Homestead 256
#   # Frontier 396
#   # Byzantium 263
#   # EIP158ToByzantiumAt5 1
#   # EIP158 233
#   # HomesteadToDaoAt5 4
#   # Constantinople 285
#   # HomesteadToEIP150At5 1
#   # FrontierToHomesteadAt5 7
#   # ByzantiumToConstantinopleFixAt5 1

# sealEngine -> NOT every fixture has it
#   # NoProof 1709
#   # Ethash 112

# blocks -> every fixture has it, an array of blocks ranging from 1 block to 303 blocks
#   # transactions 6230 can be empty
#   #   # to 6089 -> "" if contractCreation
#   #   # value 6089
#   #   # gasLimit 6089 -> "gas"
#   #   # s 6089
#   #   # r 6089
#   #   # gasPrice 6089
#   #   # v 6089
#   #   # data 6089 -> "input"
#   #   # nonce 6089
#   # blockHeader 6230 can be not present, e.g. bad rlp
#   # uncleHeaders 6230 can be empty

#   # rlp 6810 has rlp but no blockheader, usually has exception
#   # blocknumber 2733
#   # chainname 1821 -> 'A' to 'H', and 'AA' to 'DD'
#   # chainnetwork 21 -> all values are "Frontier"
#   # expectExceptionALL 420
#   #   # UncleInChain 55
#   #   # InvalidTimestamp 42
#   #   # InvalidGasLimit 42
#   #   # InvalidNumber 42
#   #   # InvalidDifficulty 35
#   #   # InvalidBlockNonce 28
#   #   # InvalidUncleParentHash 26
#   #   # ExtraDataTooBig 21
#   #   # InvalidStateRoot 21
#   #   # ExtraDataIncorrect 19
#   #   # UnknownParent 16
#   #   # TooMuchGasUsed 14
#   #   # InvalidReceiptsStateRoot 9
#   #   # InvalidUnclesHash 7
#   #   # UncleIsBrother 7
#   #   # UncleTooOld 7
#   #   # InvalidTransactionsRoot 7
#   #   # InvalidGasUsed 7
#   #   # InvalidLogBloom 7
#   #   # TooManyUncles 7
#   #   # OutOfGasIntrinsic 1
#   # expectExceptionEIP150 17
#   #   # TooMuchGasUsed 7
#   #   # InvalidReceiptsStateRoot 7
#   #   # InvalidStateRoot 3
#   # expectExceptionByzantium 17
#   #   # InvalidStateRoot 10
#   #   # TooMuchGasUsed 7
#   # expectExceptionHomestead 17
#   #   # InvalidReceiptsStateRoot 7
#   #   # BlockGasLimitReached 7
#   #   # InvalidStateRoot 3
#   # expectExceptionConstantinople 14
#   #   # InvalidStateRoot 7
#   #   # TooMuchGasUsed 7
#   # expectExceptionEIP158 14
#   #   # TooMuchGasUsed 7
#   #   # InvalidReceiptsStateRoot 7
#   # expectExceptionFrontier 14
#   #   # InvalidReceiptsStateRoot 7
#   #   # BlockGasLimitReached 7
#   # expectExceptionConstantinopleFix 14
#   #   # InvalidStateRoot 7
#   #   # TooMuchGasUsed 7
