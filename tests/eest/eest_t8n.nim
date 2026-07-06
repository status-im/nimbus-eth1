# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# To make the isMainModule functionality work
{.define: unittest2DisableParamFiltering.}

import
  std/[os, json, options, tables, strutils],
  unittest2,
  eth/rlp,
  eth/common/eth_types_rlp,
  web3/conversions,
  json_serialization,
  json_serialization/pkg/results,
  ../../execution_chain/common/chain_config,
  ../../tools/t8n/[
    helpers,
    types,
    config,
    transition,
    serialize_bal
  ],
  ./chain_config_wrapper,
  ./eest_parser

type
  BCBlock* = object
    rlp*: seq[byte]
    blockAccessList*: Opt[JsonString]
    expectException*: Opt[string]

  BCData* = object
    blocks*: seq[BCBlock]
    genesisRLP*: seq[byte]
    network*: string
    pre*: GenesisAlloc
    postState*: JsonString
    config*: EnvConfig

  BCUnit* = object
    name*: string
    data*: BCData

  BCFile* = object
    units*: seq[BCUnit]

BCData.useDefaultReaderIn T8Conv
BCBlock.useDefaultReaderIn T8Conv
EnvConfig.useDefaultReaderIn T8Conv
BlobSchedule.useDefaultReaderIn T8Conv

T8Conv.automaticSerialization(seq[BCBlock], true)

template wrapValueError(body: untyped) =
  try:
    body
  except ValueError as exc:
    r.raiseUnexpectedValue(exc.msg)

proc readValue*(
    r: var JsonReader[T8Conv],
    value: var array[HardFork.Cancun .. HardFork.high, Opt[BlobSchedule]],
) {.gcsafe, raises: [SerializationError, IOError].} =
  wrapValueError:
    for key in r.readObjectFields:
      blobScheduleParser(r, key, value)

proc readValue*(r: var JsonReader[T8Conv], val: var BCFile)
       {.gcsafe, raises: [IOError, SerializationError].} =
  r.parseObject(key):
    val.units.add BCUnit(
      name: key,
      data: r.readValue(BCData)
    )

func toBlocks(list: openArray[BCBlock]): seq[Block] =
  result = newSeqOfCap[Block](list.len)
  for x in list:
    try:
      result.add rlp.decode(x.rlp, Block)
    except RlpError:
      # invalid rlp will not participate in block validation
      discard

func collectHashes(genesis: Block, blocks: openArray[Block]): Table[uint64, Hash32] =
  result[genesis.header.number] = computeRlpHash(genesis.header)
  for blk in blocks:
    result[blk.header.number] = computeRlpHash(blk.header)

func eth(n: int): UInt256 {.compileTime.} =
  n.u256 * pow(10.u256, 18)

const
  eth5 = 5.eth
  eth3 = 3.eth
  eth2 = 2.eth

func blockReward(network: string, number: uint64): Option[UInt256] =
  case network:
  of $TestFork.Frontier, $TestFork.Homestead, $TestFork.EIP150,
     $TestFork.TangerineWhistle, $TestFork.EIP158, $TestFork.SpuriousDragon,
     $TestFork.FrontierToHomesteadAt5, $TestFork.HomesteadToEIP150At5,
     $TestFork.HomesteadToDaoAt5:
    some(eth5)
  of $TestFork.EIP158ToByzantiumAt5:
    if number < 5: some(eth5)
    else: some(eth3)
  of $TestFork.Byzantium:
    some(eth3)
  of $TestFork.ByzantiumToConstantinopleAt5,
     $TestFork.ByzantiumToConstantinopleFixAt5:
    if number < 5: some(eth3)
    else: some(eth2)
  of $TestFork.Constantinople, $TestFork.ConstantinopleFix,
     $TestFork.Istanbul, $TestFork.ConstantinopleFixToIstanbulAt5,
     $TestFork.Berlin, $TestFork.BerlinToLondonAt5, $TestFork.London,
     $TestFork.ArrowGlacier, $TestFork.GrayGlacier:
    some(eth2)
  else:
    none(UInt256)

proc toEnvStruct(parentBlock, currentBlock: Block, hashes: Table[uint64, Hash32]): EnvStruct =
  let
    parent = parentBlock.header
    current = currentBlock.header

  EnvStruct(
    currentCoinbase       : current.coinbase,
    currentDifficulty     : Opt.some current.difficulty,
    currentRandom         : Opt.some current.mixHash,
    currentGasLimit       : current.gasLimit,
    currentNumber         : current.number,
    currentTimestamp      : current.timestamp,
    slotNumber            : current.slotNumber,

    # t8n should able to calculate these 3 values itself if not supplied
    currentBaseFee        : current.baseFeePerGas,
    currentBlobGasUsed    : current.blobGasUsed,
    currentExcessBlobGas  : current.excessBlobGas,

    parentBeaconBlockRoot : current.parentBeaconBlockRoot,
    parentDifficulty      : Opt.some parent.difficulty,
    parentTimestamp       : parent.timestamp,
    parentUncleHash       : parent.ommersHash,

    parentBaseFee         : parent.baseFeePerGas,
    parentGasUsed         : Opt.some parent.gasUsed,
    parentGasLimit        : Opt.some parent.gasLimit,
    parentBlobGasUsed     : parent.blobGasUsed,
    parentExcessBlobGas   : parent.excessBlobGas,
    withdrawals           : currentBlock.withdrawals,
    blockHashes           : hashes,
    depositContractAddress: chainConfigForNetwork(MainNet).depositContractAddress,
  )

template excessBlobGas(res: ExecutionResult): auto =
  res.currentExcessBlobGas

template transactionsRoot(res: ExecutionResult): auto =
  res.txRoot

template baseFeePerGas(res: ExecutionResult): auto =
  res.currentBaseFee

func toString[X](x: X): string =
  $(x)

func toString[X](x: Opt[X]): string =
  if x.isNone:
    "none"
  else:
    toString(x.value)

template noAction() =
  discard

template validateField(F: untyped, body: untyped = noAction) =
  if res.result.F != header.F:
    body
    return err(astToStr(F) & " mismatch, got: " & res.result.F.toString &
      ", want: " & header.F.toString )

template debugState() =
  let expectedAlloc = T8Conv.decode(bcdata.postState, GenesisAlloc)
  debugEcho "got state: ",
    @@(res.alloc).pretty,
    ", expected state: ",
    @@(expectedAlloc).pretty

func getRequests(unit: EngineUnitEnv, number: uint64): Result[string, string] =
  for payload in unit.engineNewPayloads:
    if payload.params.payload.blockNumber.uint64 == number:
      if payload.params.executionRequests.isSome:
        return ok(@@(payload.params.executionRequests.value).pretty)
  err("cannot get requests from engine fixture")

proc parseRequests(filePath: string, unitIndex: int, header: Header): Result[string, string] =
  try:
    let
      engineFile = filePath.replace("blockchain_tests", "blockchain_tests_engine")
      fixture = EthJson.loadFile(engineFile, EngineFixture)
      unit = fixture.units[unitIndex].unit
    unit.getRequests(header.number)
  except JsonReaderError as exc:
    err(exc.formatMsg(filePath))
  except IOError as exc:
    err("IO ERROR: " & exc.msg)
  except SerializationError as exc:
    err("Serialization error: " & exc.msg)

template debugRequests() =
  let expectedRequests = parseRequests(filePath, unitIndex, header).valueOr:
    "Expected requests not available: " & error

  debugEcho "got requests: ",
    @@(res.result.requests).pretty,
    ", expected requests: ",
    expectedRequests

template debugExcessBlobGas() =
  debugEcho "from header excessBlobGas: ", header.excessBlobGas

proc prettyBAL(bal: Opt[JsonString]): string =
  if bal.isNone:
    return "none"
  parseJson(bal.value.string).pretty

template debugBlockAccessList() =
  let expectedBal = bal.prettyBAL()
  debugEcho "got blockAccessList: ",
    @@(res.result.blockAccessList).pretty,
    ", expected blockAccessList: ",
    expectedBal

proc compareResult(res: ExecOutput,
                   header: Header,
                   bcdata: BCData,
                   filePath: string,
                   unitIndex: int,
                   bal: Opt[JsonString]): Result[void, string] =
  validateField(stateRoot, debugState)
  validateField(transactionsRoot)
  validateField(receiptsRoot)
  validateField(logsBloom)
  validateField(gasUsed)
  validateField(withdrawalsRoot)
  validateField(blobGasUsed)
  validateField(baseFeePerGas)
  validateField(excessBlobGas, debugExcessBlobGas)
  validateField(requestsHash, debugRequests)
  validateField(blockAccessListHash, debugBlockAccessList)

  ok()

proc runTest(bcdata: BCData, filePath: string, unitIndex: int): Result[void, string] =
  var
    prevAlloc = bcdata.pre
    prevBlock = rlp.decode(bcdata.genesisRLP, Block)

  let
    blocks = toBlocks(bcdata.blocks)
    hashes = collectHashes(prevBlock, blocks)

  for i, currBlock in blocks:
    if bcdata.blocks[i].expectException.isSome:
      continue

    let
      conf = T8NConf(
        stateReward: blockReward(bcdata.network, currBlock.header.number),
        stateChainId: MainNet,
        stateFork: bcdata.network,
      )

    var
      ctx = TransContext(
        alloc: prevAlloc,
        txsRlp: rlp.encode(currBlock.transactions),
        env: toEnvStruct(prevBlock, currBlock, hashes),
      )

    var
      res = ctx.transitionAction(conf, Opt.some(bcdata.config.blobSchedule))

    ? compareResult(res,
        currBlock.header,
        bcdata,
        filePath,
        unitIndex,
        bcdata.blocks[i].blockAccessList)

    prevBlock = currBlock
    prevAlloc = move(res.alloc)

  ok()

proc processFile*(filePath: string, statelessEnabled = false, parallelEnabled = false, skipFiles: seq[string] = @[]) =
  let
    BCFile = T8Conv.loadFile(filePath, BCFile, allowUnknownFields = true)
    fileName = filePath.splitPath().tail

  for unitIndex, unit in BCFile.units:
    let
      testName = unit.name
      testData = unit.data
    test testName & " from " & filePath:
      if fileName in skipFiles:
        skip()
      else:
        let testResult = runTest(testData, filePath, unitIndex)
        check testResult == Result[void, string].ok()

when isMainModule:
  import std/cmdline

  if paramCount() == 0:
    let testFile = getAppFilename().splitPath().tail
    echo "Usage: " & testFile & " vector.json"
    quit(QuitFailure)

  processFile(paramStr(1), statelessEnabled = false)
