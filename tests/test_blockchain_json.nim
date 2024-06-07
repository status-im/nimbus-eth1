# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, os, tables, strutils, options, streams],
  unittest2,
  eth/rlp, eth/trie/trie_defs, eth/common/eth_types_rlp,
  stew/byteutils,
  ./test_helpers, ./test_allowed_to_fail,
  ../premix/parser, test_config,
  ../nimbus/[vm_state, vm_types, errors, constants],
  ../nimbus/db/[ledger, state_db],
  ../nimbus/utils/[utils, debug],
  ../nimbus/evm/tracer/legacy_tracer,
  ../nimbus/evm/tracer/json_tracer,
  ../nimbus/core/[validate, chain, pow/header],
  ../stateless/[tree_from_witness, witness_types],
  ../tools/common/helpers as chp,
  ../tools/evmstate/helpers,
  ../nimbus/common/common,
  ../nimbus/core/eip4844,
  ../nimbus/rpc/experimental

type
  SealEngine = enum
    NoProof
    Ethash

  TestBlock = object
    goodBlock: bool
    blockRLP : Blob
    header   : BlockHeader
    body     : BlockBody
    hasException: bool
    withdrawals: Option[seq[Withdrawal]]

  TestCtx = object
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
    json         : bool

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
    var i = 2
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

func normalizeWithdrawal(node: JsonNode): JsonNode =
  for k, v in node:
    case k
    of "amount", "index", "validatorIndex":
      node[k] = normalizeNumber(v)
    else: discard
  result = node

proc parseHeader(blockHeader: JsonNode, testStatusIMPL: var TestStatus): BlockHeader =
  result = normalizeBlockHeader(blockHeader).parseBlockHeader
  var blockHash: Hash256
  blockHeader.fromJson "hash", blockHash
  check blockHash == hash(result)

proc parseWithdrawals(withdrawals: JsonNode): Option[seq[Withdrawal]] =
  case withdrawals.kind
  of JArray:
    var ws: seq[Withdrawal]
    for v in withdrawals:
      ws.add(parseWithdrawal(normalizeWithdrawal(v)))
    some(ws)
  else:
    none[seq[Withdrawal]]()

proc parseBlocks(blocks: JsonNode): seq[TestBlock] =
  for fixture in blocks:
    var t: TestBlock
    t.withdrawals = none[seq[Withdrawal]]()
    for key, value in fixture:
      case key
      of "blockHeader":
        # header is absent in bad block
        t.goodBlock = true
      of "rlp":
        fixture.fromJson "rlp", t.blockRLP
      of "transactions", "uncleHeaders", "hasBigInt",
         "blocknumber", "chainname", "chainnetwork":
        discard
      of "transactionSequence":
        var noError = true
        for tx in value:
          let valid = tx["valid"].getStr == "true"
          noError = noError and valid
        doAssert(noError == false, "NOT A VALID TEST CASE")
      of "withdrawals":
        t.withdrawals = parseWithdrawals(value)
      of "rlp_decoded":
        # this field is intended for client who
        # doesn't support rlp encoding(e.g. evmone)
        discard
      else:
        doAssert("expectException" in key, key)
        t.hasException = true

    result.add t

proc parseTestCtx(fixture: JsonNode, testStatusIMPL: var TestStatus): TestCtx =
  result.blocks = parseBlocks(fixture["blocks"])

  fixture.fromJson "lastblockhash", result.lastBlockHash

  if "genesisRLP" in fixture:
    var genesisRLP: Blob
    fixture.fromJson "genesisRLP", genesisRLP
    result.genesisHeader = rlp.decode(genesisRLP, EthBlock).header
  else:
    result.genesisHeader = parseHeader(fixture["genesisBlockHeader"], testStatusIMPL)
    var goodBlock = true
    for h in result.blocks:
      goodBlock = goodBlock and h.goodBlock
    check goodBlock == false

  if "sealEngine" in fixture:
    result.sealEngine = some(parseEnum[SealEngine](fixture["sealEngine"].getStr))

  if "postStateHash" in fixture:
    result.postStateHash.data = hexToByteArray[32](fixture["postStateHash"].getStr)

  result.network = fixture["network"].getStr

proc blockWitness(vmState: BaseVMState, chainDB: CoreDbRef) =
  let rootHash = vmState.stateDB.rootHash
  let witness = vmState.buildWitness()

  if witness.len() == 0:
    if vmState.stateDB.makeMultiKeys().keys.len() != 0:
      raise newException(ValidationError, "Invalid trie generated from block witness")
    return

  let fork = vmState.fork
  let flags = if fork >= FkSpurious: {wfEIP170} else: {}

  # build tree from witness
  var db = newCoreDbRef DefaultDbMemory
  when defined(useInputStream):
    var input = memoryInput(witness)
    var tb = initTreeBuilder(input, db, flags)
  else:
    var tb = initTreeBuilder(witness, db, flags)
  let root = tb.buildTree()

  # compare the result
  if root != rootHash:
    raise newException(ValidationError, "Invalid trie generated from block witness")

proc testGetBlockWitness(chain: ChainRef, parentHeader, currentHeader: BlockHeader) =
  # check that current state matches current header
  let currentStateRoot = chain.vmState.stateDB.rootHash
  if currentStateRoot != currentHeader.stateRoot:
    raise newException(ValidationError, "Expected currentStateRoot == currentHeader.stateRoot")

  let (mkeys, witness) = getBlockWitness(chain.com, currentHeader, false)

  # check that the vmstate hasn't changed after call to getBlockWitness
  if chain.vmState.stateDB.rootHash != currentHeader.stateRoot:
    raise newException(ValidationError, "Expected chain.vmstate.stateDB.rootHash == currentHeader.stateRoot")

  # check the witnessRoot against the witness tree if the witness isn't empty
  if witness.len() > 0:
    let fgs = if chain.vmState.fork >= FkSpurious: {wfEIP170} else: {}
    var tb = initTreeBuilder(witness, chain.com.db, fgs)
    let witnessRoot = tb.buildTree()
    if witnessRoot != parentHeader.stateRoot:
      raise newException(ValidationError, "Expected witnessRoot == parentHeader.stateRoot")

  # use the MultiKeysRef to build the block proofs
  let
    ac = newAccountStateDB(chain.com.db, currentHeader.stateRoot)
    blockProofs = getBlockProofs(state_db.ReadOnlyStateDB(ac), mkeys)
  if witness.len() == 0 and blockProofs.len() != 0:
    raise newException(ValidationError, "Expected blockProofs.len() == 0")

proc setupTracer(ctx: TestCtx): TracerRef =
  if ctx.trace:
    if ctx.json:
      var tracerFlags = {
        TracerFlags.DisableMemory,
        TracerFlags.DisableStorage,
        TracerFlags.DisableState,
        TracerFlags.DisableStateDiff,
        TracerFlags.DisableReturnData
      }
      let stream = newFileStream(stdout)
      newJsonTracer(stream, tracerFlags, false)
    else:
      newLegacyTracer({})
  else:
    TracerRef()

proc importBlock(ctx: var TestCtx, com: CommonRef,
                 tb: TestBlock, checkSeal: bool) =
  if ctx.vmState.isNil or ctx.vmState.stateDB.isTopLevelClean.not:
    let
      parentHeader = com.db.getBlockHeader(tb.header.parentHash)
      tracerInst = ctx.setupTracer()
    ctx.vmState = BaseVMState.new(
      parentHeader,
      tb.header,
      com,
      tracerInst,
    )
    ctx.vmState.generateWitness = true # Enable saving witness data

  let
    chain = newChain(com, extraValidation = true, ctx.vmState)
    res = chain.persistBlocks([tb.header], [tb.body])

  if res.isErr():
    raise newException(ValidationError, res.error())
  else:
    blockWitness(chain.vmState, com.db)
    testGetBlockWitness(chain, chain.vmState.parent, tb.header)

proc applyFixtureBlockToChain(ctx: var TestCtx, tb: var TestBlock,
                              com: CommonRef, checkSeal: bool) =
  decompose(tb.blockRLP, tb.header, tb.body)
  ctx.importBlock(com, tb, checkSeal)

func shouldCheckSeal(ctx: TestCtx): bool =
  if ctx.sealEngine.isSome:
    result = ctx.sealEngine.get() != NoProof

proc collectDebugData(ctx: var TestCtx) =
  if ctx.vmState.isNil:
    return

  let vmState = ctx.vmState
  let tracerInst = LegacyTracer(vmState.tracer)
  let tracingResult = if ctx.trace: tracerInst.getTracingResult() else: %[]
  ctx.debugData.add %{
    "blockNumber": %($vmState.blockNumber),
    "structLogs": tracingResult,
  }

proc runTestCtx(ctx: var TestCtx, com: CommonRef, testStatusIMPL: var TestStatus) =
  discard com.db.persistHeaderToDb(ctx.genesisHeader,
    com.consensus == ConsensusType.POS)
  check com.db.getCanonicalHead().blockHash == ctx.genesisHeader.blockHash
  let checkSeal = ctx.shouldCheckSeal

  if ctx.debugMode:
    ctx.debugData = newJArray()

  for idx, tb in ctx.blocks:
    if tb.goodBlock:
      try:

        ctx.applyFixtureBlockToChain(
          ctx.blocks[idx], com, checkSeal)

      except CatchableError as ex:
        debugEcho "FATAL ERROR(WE HAVE BUG): ", ex.msg

    else:
      var noError = true
      try:
        ctx.applyFixtureBlockToChain(ctx.blocks[idx],
          com, checkSeal)
      except ValueError, ValidationError, BlockNotFound, RlpError:
        # failure is expected on this bad block
        check (tb.hasException or (not tb.goodBlock))
        noError = false
        if ctx.debugMode:
          ctx.debugData.add %{
            "exception": %($getCurrentException().name),
            "msg": %getCurrentExceptionMsg()
          }

      # Block should have caused a validation error
      check noError == false

    if ctx.debugMode and not ctx.json:
      ctx.collectDebugData()

proc debugDataFromAccountList(ctx: TestCtx): JsonNode =
  let vmState = ctx.vmState
  result = %{"debugData": ctx.debugData}
  if not vmState.isNil:
    result["accounts"] = vmState.dumpAccounts()

proc debugDataFromPostStateHash(ctx: TestCtx): JsonNode =
  let vmState = ctx.vmState
  %{
    "debugData": ctx.debugData,
    "postStateHash": %($vmState.readOnlyStateDB.rootHash),
    "expectedStateHash": %($ctx.postStateHash),
    "accounts": vmState.dumpAccounts()
  }

proc dumpDebugData(ctx: TestCtx, fixtureName: string, fixtureIndex: int, success: bool) =
  let debugData = if ctx.postStateHash != Hash256():
                    debugDataFromPostStateHash(ctx)
                  else:
                    debugDataFromAccountList(ctx)

  let status = if success: "_success" else: "_failed"
  let name = fixtureName.replace('/', '-').replace(':', '-')
  writeFile("debug_" & name & "_" & $fixtureIndex & status & ".json", debugData.pretty())

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus, debugMode = false, trace = false) =
  # 1 - mine the genesis block
  # 2 - loop over blocks:
  #     - apply transactions
  #     - mine block
  # 3 - diff resulting state with expected state
  # 4 - check that all previous blocks were valid
  let specifyIndex = test_config.getConfiguration().index.get(0)
  var fixtureIndex = 0
  var fixtureTested = false

  for fixtureName, fixture in node:
    inc fixtureIndex
    if specifyIndex > 0 and fixtureIndex != specifyIndex:
      continue

    var ctx = parseTestCtx(fixture, testStatusIMPL)

    let
      memDB     = newCoreDbRef DefaultDbMemory
      stateDB   = LedgerRef.init(memDB, emptyRlpHash)
      config    = getChainConfig(ctx.network)
      com       = CommonRef.new(memDB, config)

    setupStateDB(fixture["pre"], stateDB)
    stateDB.persist()

    check stateDB.rootHash == ctx.genesisHeader.stateRoot

    ctx.debugMode = debugMode
    ctx.trace = trace
    ctx.json = test_config.getConfiguration().json

    var success = true
    try:
      ctx.runTestCtx(com, testStatusIMPL)
      let header = com.db.getCanonicalHead()
      let lastBlockHash = header.blockHash
      check lastBlockHash == ctx.lastBlockHash
      success = lastBlockHash == ctx.lastBlockHash
      if ctx.postStateHash != Hash256():
        let rootHash = ctx.vmState.stateDB.rootHash
        if ctx.postStateHash != rootHash:
          raise newException(ValidationError, "incorrect postStateHash, expect=" &
            $rootHash & ", get=" &
            $ctx.postStateHash
          )
      elif lastBlockHash == ctx.lastBlockHash:
        # multiple chain, we are using the last valid canonical
        # state root to test against 'postState'
        let stateDB = LedgerRef.init(memDB, header.stateRoot)
        verifyStateDB(fixture["postState"], ledger.ReadOnlyStateDB(stateDB))

      success = lastBlockHash == ctx.lastBlockHash
    except ValidationError as E:
      echo fixtureName, " ERROR: ", E.msg
      success = false

    if ctx.debugMode:
      ctx.dumpDebugData(fixtureName, fixtureIndex, success)

    fixtureTested = true
    check success == true

  if not fixtureTested:
    echo test_config.getConfiguration().testSubject, " not tested at all, wrong index?"
    if specifyIndex <= 0 or specifyIndex > node.len:
      echo "Maximum subtest available: ", node.len

proc blockchainJsonMain*(debugMode = false) =
  const
    legacyFolder = "eth_tests/LegacyTests/Constantinople/BlockchainTests"
    newFolder = "eth_tests/BlockchainTests"
    #newFolder = "eth_tests/EIPTests/BlockchainTests"
    #newFolder = "eth_tests/EIPTests/Pyspecs/cancun"

  let res = loadKzgTrustedSetup()
  if res.isErr:
    echo "FATAL: ", res.error
    quit(QuitFailure)

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
    let path = "tests/fixtures/" & folder
    let n = json.parseFile(path / config.testSubject)
    var testStatusIMPL: TestStatus
    testFixture(n, testStatusIMPL, debugMode = true, config.trace)

when isMainModule:
  import std/times
  var message: string

  let start = getTime()

  ## Processing command line arguments
  if test_config.processArguments(message) != test_config.Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  blockchainJsonMain(true)
  let elpd = getTime() - start
  echo "TIME: ", elpd

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
