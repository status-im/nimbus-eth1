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
  ../nimbus/[vm_state, utils, vm_types, errors, transaction, constants, vm_types2],
  ../nimbus/db/[db_chain, accounts_cache],
  ../nimbus/utils/header,
  ../nimbus/p2p/[executor, dao],
  ../nimbus/[config, chain_config],
  ../stateless/[tree_from_witness, witness_types]

type
  SealEngine = enum
    NoProof
    Ethash

  EthBlock = object
    header      : BlockHeader
    transactions: seq[Transaction]
    uncles      : seq[BlockHeader]

  TestBlock = object
    goodBlock: bool
    blockRLP : Blob
    hasException: bool

  Tester = object
    lastBlockHash: Hash256
    genesisHeader: BlockHeader
    blocks       : seq[TestBlock]
    sealEngine   : Option[SealEngine]
    debugMode    : bool
    trace        : bool
    vmState      : BaseVMState
    debugData    : JsonNode
    network      : string

  MiningHeader = object
    parentHash  : Hash256
    ommersHash  : Hash256
    coinbase    : EthAddress
    stateRoot   : Hash256
    txRoot      : Hash256
    receiptRoot : Hash256
    bloom       : common.BloomFilter
    difficulty  : DifficultyInt
    blockNumber : BlockNumber
    gasLimit    : GasInt
    gasUsed     : GasInt
    timestamp   : EthTime
    extraData   : Blob

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus, debugMode = false, trace = false)

func normalizeNumber(n: JsonNode): JsonNode =
  let str = n.getStr
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

proc parseBlocks(blocks: JsonNode): seq[TestBlock] =
  for fixture in blocks:
    var t: TestBlock
    for key, value in fixture:
      case key
      of "blockHeader":
        # header is absent in bad block
        t.goodBlock = true
      of "rlp":
        fixture.fromJson "rlp", t.blockRLP
      of "transactions", "uncleHeaders",
         "blocknumber", "chainname", "chainnetwork":
        discard
      else:
        t.hasException = true

    result.add t

func vmConfiguration(network: string, c: var ChainConfig) =
  const
    H = high(BlockNumber)
    Zero = 0.toBlockNumber
    Five = 5.toBlockNumber

  proc assignNumber(c: var ChainConfig,
                    fork: Fork, n: BlockNumber) =
    var number: array[Fork, BlockNumber]
    var z = low(Fork)
    while z < fork:
      number[z] = Zero
      z = z.succ
    number[fork] = n
    z = high(Fork)
    while z > fork:
      number[z] = H
      z = z.pred

    c.daoForkSupport = false
    c.homesteadBlock      = number[FkHomestead]
    c.daoForkBlock        = number[FkHomestead]
    c.eip150Block         = number[FkTangerine]
    c.eip155Block         = number[FkSpurious]
    c.eip158Block         = number[FkSpurious]
    c.byzantiumBlock      = number[FkByzantium]
    c.constantinopleBlock = number[FkConstantinople]
    c.petersburgBlock     = number[FkPetersburg]
    c.istanbulBlock       = number[FkIstanbul]
    c.muirGlacierBlock    = number[FkBerlin]
    c.berlinBlock         = number[FkBerlin]

  case network
  of "EIP150":
    c.assignNumber(FkTangerine, Zero)
  of "ConstantinopleFix":
    c.assignNumber(FkPetersburg, Zero)
  of "Homestead":
    c.assignNumber(FkHomestead, Zero)
  of "Frontier":
    c.assignNumber(FkFrontier, Zero)
  of "Byzantium":
    c.assignNumber(FkByzantium, Zero)
  of "EIP158ToByzantiumAt5":
    c.assignNumber(FkByzantium, Five)
  of "EIP158":
    c.assignNumber(FkSpurious, Zero)
  of "HomesteadToDaoAt5":
    c.assignNumber(FkHomestead, Zero)
    c.daoForkBlock = Five
    c.daoForkSupport = true
  of "Constantinople":
    c.assignNumber(FkConstantinople, Zero)
  of "HomesteadToEIP150At5":
    c.assignNumber(FkTangerine, Five)
  of "FrontierToHomesteadAt5":
    c.assignNumber(FkHomestead, Five)
  of "ByzantiumToConstantinopleFixAt5":
    c.assignNumber(FkPetersburg, Five)
    c.constantinopleBlock = Five
  of "Istanbul":
    c.assignNumber(FkIstanbul, Zero)
  of "Berlin":
    c.assignNumber(FkBerlin, Zero)
  else:
    raise newException(ValueError, "unsupported network " & network)

proc parseTester(fixture: JsonNode, testStatusIMPL: var TestStatus): Tester =
  result.blocks = parseBlocks(fixture["blocks"])

  fixture.fromJson "lastblockhash", result.lastBlockHash
  result.genesisHeader = parseHeader(fixture["genesisBlockHeader"], testStatusIMPL)

  if "genesisRLP" in fixture:
    var genesisRLP: Blob
    fixture.fromJson "genesisRLP", genesisRLP
    let genesisBlock = EthBlock(header: result.genesisHeader)
    check genesisRLP == rlp.encode(genesisBlock)
  else:
    var goodBlock = true
    for h in result.blocks:
      goodBlock = goodBlock and h.goodBlock
    check goodBlock == false

  if "sealEngine" in fixture:
    result.sealEngine = some(parseEnum[SealEngine](fixture["sealEngine"].getStr))
  result.network = fixture["network"].getStr

proc blockWitness(vmState: BaseVMState, chainDB: BaseChainDB) =
  let rootHash = vmState.accountDb.rootHash
  let witness = vmState.buildWitness()
  let fork = vmState.fork
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

func validateBlockUnchanged(a, b: EthBlock): bool =
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

proc validateUncles(chainDB: BaseChainDB, currBlock: EthBlock, checkSeal: bool) =
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

func isGenesis(currBlock: EthBlock): bool =
  result = currBlock.header.blockNumber == 0.u256 and currBlock.header.parentHash == GENESIS_PARENT_HASH

proc validateBlock(chainDB: BaseChainDB, currBlock: EthBlock, checkSeal: bool): bool =
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
  preminedBlock: EthBlock, tb: TestBlock, checkSeal, validation: bool, testStatusIMPL: var TestStatus): EthBlock =

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

  let body = BlockBody(
    transactions: result.transactions,
    uncles: result.uncles
  )
  let res = processBlock(chainDB, result.header, body, tester.vmState)
  if res == ValidationResult.Error:
    check (tb.hasException or (not tb.goodBlock))
  else:
    if tester.vmState.generateWitness():
      blockWitness(tester.vmState, chainDB)

  result.header.stateRoot  = tester.vmState.blockHeader.stateRoot
  result.header.parentHash = parentHeader.hash
  result.header.difficulty = baseHeaderForImport.difficulty

  if validation:
    if not validateBlockUnchanged(result, preminedBlock):
      raise newException(ValidationError, "block changed")
    if not validateBlock(chainDB, result, checkSeal):
      raise newException(ValidationError, "invalid block")

  discard chainDB.persistHeaderToDb(preminedBlock.header)

proc applyFixtureBlockToChain(tester: var Tester, tb: TestBlock,
  chainDB: BaseChainDB, checkSeal, validation: bool, testStatusIMPL: var TestStatus): (EthBlock, EthBlock, Blob) =

  # we hack the ChainConfig here and let it works with calcDifficulty
  vmConfiguration(tester.network, chainDB.config)

  var
    preminedBlock = rlp.decode(tb.blockRLP, EthBlock)
    minedBlock = tester.importBlock(chainDB, preminedBlock, tb, checkSeal, validation, testStatusIMPL)
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
  discard chainDB.persistHeaderToDb(tester.genesisHeader)
  check chainDB.getCanonicalHead().blockHash == tester.genesisHeader.blockHash
  let checkSeal = tester.shouldCheckSeal

  if tester.debugMode:
    tester.debugData = newJArray()

  for idx, testBlock in tester.blocks:
    if testBlock.goodBlock:
      try:
        let (preminedBlock, _, _) = tester.applyFixtureBlockToChain(
            testBlock, chainDB, checkSeal, validation = false, testStatusIMPL)  # we manually validate below
        check validateBlock(chainDB, preminedBlock, checkSeal) == true
      except:
        debugEcho "FATAL ERROR(WE HAVE BUG): ", getCurrentExceptionMsg()

    else:
      var noError = true
      try:
        let (_, _, _) = tester.applyFixtureBlockToChain(testBlock,
          chainDB, checkSeal, validation = true, testStatusIMPL)
      except ValueError, ValidationError, BlockNotFound, MalformedRlpError, RlpTypeMismatch:
        # failure is expected on this bad block
        check (testBlock.hasException or (not testBlock.goodBlock))
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

    var vmState = newBaseVMState(emptyRlpHash,
      tester.genesisHeader, chainDB)

    vmState.generateWitness = true

    vmState.mutateStateDB:
      setupStateDB(fixture["pre"], db)
      db.persist()

    let obtainedHash = $(vmState.readOnlyStateDB.rootHash)
    check obtainedHash == $(tester.genesisHeader.stateRoot)

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
  const
    legacyFolder = "eth_tests" / "LegacyTests" / "Constantinople" / "BlockchainTests"
    newFolder = "eth_tests" / "BlockchainTests"

  let config = test_config.getConfiguration()
  if config.testSubject == "" or not debugMode:
    # run all test fixtures
    if config.legacy:
      suite "block chain json tests":
        jsonTest(legacyFolder, "BlockchainTests", testFixture, skipBCTests)
    else:
      suite "new block chain json tests":
        jsonTest(newFolder, "newBlockchainTests", testFixture, skipNewBCTests)
  else:
    # execute single test in debug mode
    if config.testSubject.len == 0:
      echo "missing test subject"
      quit(QuitFailure)

    let folder = if config.legacy: legacyFolder else: newFolder
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

  disableParamFiltering()
  blockchainJsonMain(true)

# lastBlockHash -> every fixture has it, hash of a block header
# genesisRLP -> NOT every fixture has it, rlp bytes of genesis block header
# _info -> every fixture has it, can be omitted
# pre, postState -> every fixture has it, prestate and post state
# genesisHeader -> every fixture has it
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
