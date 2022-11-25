# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  unittest2, json, os, tables, strutils, sets,
  options,
  eth/[common, rlp], eth/trie/[db, trie_defs],
  stew/[endians2, byteutils],
  ./test_helpers, ./test_allowed_to_fail,
  ../premix/parser, test_config,
  ../nimbus/[vm_state, utils, vm_types, errors, constants, forks],
  ../nimbus/db/[db_chain, accounts_cache],
  ../nimbus/utils/header,
  ../nimbus/p2p/[executor, validate],
  ../nimbus/chain_config,
  ../stateless/[tree_from_witness, witness_types],
  ../tools/common/helpers

type
  SealEngine = enum
    NoProof
    Ethash

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
    postStateHash: Hash256

var pow = PowRef.new

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
      "gasLimit", "timestamp", "baseFeePerGas":
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
      of "transactionSequence":
        var noError = true
        for tx in value:
          let valid = tx["valid"].getStr == "true"
          noError = noError and valid
        doAssert(noError == false, "NOT A VALID TEST CASE")
      else:
        doAssert("expectException" in key, key)
        t.hasException = true

    result.add t

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

  if "postStateHash" in fixture:
    result.postStateHash.data = hexToByteArray[32](fixture["postStateHash"].getStr)

  result.network = fixture["network"].getStr

proc blockWitness(vmState: BaseVMState, chainDB: BaseChainDB) =
  let rootHash = vmState.stateDB.rootHash
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

proc importBlock(tester: var Tester, chainDB: BaseChainDB,
  preminedBlock: EthBlock, tb: TestBlock, checkSeal, validation: bool): EthBlock =

  let parentHeader = chainDB.getBlockHeader(preminedBlock.header.parentHash)
  var baseHeaderForImport = generateHeaderFromParentHeader(chainDB.config,
      parentHeader,
      preminedBlock.header.coinbase,
      some(preminedBlock.header.timestamp),
      preminedBlock.header.gasLimit,
      @[],
      preminedBlock.header.fee
  )

  deepCopy(result, preminedBlock)
  let ttdReached = chainDB.isBlockAfterTtd(preminedBlock.header)
  if ttdReached and chainDB.config.mergeForkBlock == high(BlockNumber):
    chainDB.config.mergeForkBlock = preminedBlock.header.blockNumber

  if ttdReached:
    baseHeaderForImport.prevRandao = preminedBlock.header.prevRandao

  tester.vmState = BaseVMState.new(
    parentHeader,
    baseHeaderForImport,
    chainDB,
    (if tester.trace: {TracerFlags.EnableTracing} else: {}),
    chainDB.pruneTrie)

  let body = BlockBody(
    transactions: result.txs,
    uncles: result.uncles
  )

  if validation:
    let rc = chainDB.validateHeaderAndKinship(
      result.header, body, checkSeal, ttdReached, pow)
    if rc.isErr:
      raise newException(
        ValidationError, "validateHeaderAndKinship: " & rc.error)

  let res = tester.vmState.processBlockNotPoA(result.header, body)
  if res == ValidationResult.Error:
    if not (tb.hasException or (not tb.goodBlock)):
      raise newException(ValidationError, "process block validation")
  else:
    if tester.vmState.generateWitness():
      blockWitness(tester.vmState, chainDB)

  discard chainDB.persistHeaderToDb(preminedBlock.header)

proc applyFixtureBlockToChain(tester: var Tester, tb: TestBlock,
  chainDB: BaseChainDB, checkSeal, validation: bool): (EthBlock, EthBlock, Blob) =

  # we hack the ChainConfig here and let it works with calcDifficulty
  getChainConfig(tester.network, chainDB.config)

  var
    preminedBlock = rlp.decode(tb.blockRLP, EthBlock)
    minedBlock = tester.importBlock(chainDB, preminedBlock, tb, checkSeal, validation)
    rlpEncodedMinedBlock = rlp.encode(minedBlock)

  result = (preminedBlock, minedBlock, rlpEncodedMinedBlock)

func shouldCheckSeal(tester: Tester): bool =
  if tester.sealEngine.isSome:
    result = tester.sealEngine.get() != NoProof

proc collectDebugData(tester: var Tester) =
  if tester.vmState.isNil:
    return

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
            testBlock, chainDB, checkSeal, validation = false)

        let ttdReached = chainDB.isBlockAfterTtd(preminedBlock.header)
        if ttdReached and chainDB.config.mergeForkBlock == high(BlockNumber):
          chainDB.config.mergeForkBlock = preminedBlock.header.blockNumber

        # manually validating
        let res = chainDB.validateHeaderAndKinship(
          preminedBlock, checkSeal, ttdReached, pow)
        check res.isOk
        when defined(noisy):
          if res.isErr:
            debugEcho "blockNumber: ", preminedBlock.header.blockNumber
            debugEcho "fork: ", chainDB.config.toFork(preminedBlock.header.blockNumber)
            debugEcho "error message: ", res.error
            debugEcho "ttdReached: ", ttdReached

      except:
        debugEcho "FATAL ERROR(WE HAVE BUG): ", getCurrentExceptionMsg()

    else:
      var noError = true
      try:
        let (_, _, _) = tester.applyFixtureBlockToChain(testBlock,
          chainDB, checkSeal, validation = true)
      except ValueError, ValidationError, BlockNotFound, RlpError:
        # failure is expected on this bad block
        check (testBlock.hasException or (not testBlock.goodBlock))
        noError = false
        if tester.debugMode:
          tester.debugData.add %{
            "exception": %($getCurrentException().name),
            "msg": %getCurrentExceptionMsg()
          }

      # Block should have caused a validation error
      check noError == false

    if tester.debugMode:
      tester.collectDebugData()

proc dumpAccount(stateDB: ReadOnlyStateDB, address: EthAddress, name: string): JsonNode =
  result = %{
    "name": %name,
    "address": %($address),
    "nonce": %toHex(stateDB.getNonce(address)),
    "balance": %stateDB.getBalance(address).toHex(),
    "codehash": %($stateDB.getCodeHash(address)),
    "storageRoot": %($stateDB.getStorageRoot(address))
  }

proc dumpDebugData(tester: Tester, vmState: BaseVMState, accountList: JsonNode): JsonNode =
  var accounts = newJObject()
  var i = 0
  for ac, _ in accountList:
    let account = ethAddressFromHex(ac)
    accounts[$account] = dumpAccount(vmState.readOnlyStateDB, account, "acc" & $i)
    inc i

  %{
    "debugData": tester.debugData,
    "accounts": accounts
  }

proc accountList(fixture: JsonNode): JsonNode =
  if fixture["postState"].kind == JObject:
    fixture["postState"]
  else:
    fixture["pre"]

proc debugDataFromAccountList(tester: Tester, fixture: JsonNode): JsonNode =
  let accountList = fixture.accountList
  let vmState = tester.vmState
  if vmState.isNil:
    %{"debugData": tester.debugData}
  else:
    dumpDebugData(tester, vmState, accountList)

proc debugDataFromPostStateHash(tester: Tester): JsonNode =
  var
    accounts = newJObject()
    accountList = newSeq[EthAddress]()
    vmState = tester.vmState

  for address in vmState.stateDB.addresses:
    accountList.add address

  for i, ac in accountList:
    accounts[ac.toHex] = dumpAccount(vmState.readOnlyStateDB, ac, "acc" & $i)

  %{
    "debugData": tester.debugData,
    "postStateHash": %($vmState.readOnlyStateDB.rootHash),
    "expectedStateHash": %($tester.postStateHash),
    "accounts": accounts
  }

proc dumpDebugData(tester: Tester, fixture: JsonNode, fixtureName: string, fixtureIndex: int, success: bool) =
  let debugData = if tester.postStateHash != Hash256():
                    debugDataFromPostStateHash(tester)
                  else:
                    debugDataFromAccountList(tester, fixture)

  let status = if success: "_success" else: "_failed"
  writeFile("debug_" & fixtureName & "_" & $fixtureIndex & status & ".json", debugData.pretty())

# using only one networkParams will reduce execution
# time ~87.5% instead of create it for every test
let chainParams = networkParams(MainNet)

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

    let
      pruneTrie = test_config.getConfiguration().pruning
      chainDB = newBaseChainDB(newMemoryDb(), pruneTrie, params = chainParams)
      stateDB = AccountsCache.init(chainDB.db, emptyRlpHash, chainDB.pruneTrie)

    setupStateDB(fixture["pre"], stateDB)
    stateDB.persist()

    check stateDB.rootHash == tester.genesisHeader.stateRoot

    tester.debugMode = debugMode
    tester.trace = trace

    var success = true
    try:
      tester.runTester(chainDB, testStatusIMPL)
      let latestBlockHash = chainDB.getCanonicalHead().blockHash
      if latestBlockHash != tester.lastBlockHash:
        if tester.postStateHash != Hash256():
          let rootHash = tester.vmState.stateDB.rootHash
          if tester.postStateHash != rootHash:
            raise newException(ValidationError, "incorrect postStateHash, expect=" &
              $rootHash & ", get=" &
              $tester.postStateHash
            )
        else:
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
