# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, json, os, tables, strutils, sets, strformat,
  options,
  eth/[common, rlp, bloom], eth/trie/[db, trie_defs],
  ./test_helpers, ../premix/parser, test_config,
  ../nimbus/vm/interpreter/vm_forks,
  ../nimbus/[vm_state, utils, vm_types, errors, transaction, constants],
  ../nimbus/db/[db_chain, state_db],
  ../nimbus/utils/header,
  ../nimbus/p2p/executor

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

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus, debugMode = false)

func normalizeNumber(n: JsonNode): JsonNode =
  let str = n.getStr
  # paranoid checks
  doAssert n.kind == Jstring
  doAssert str.len > 3
  doAssert str[0] == '0' and str[1] == 'x'
  # real normalization
  # strip leading 0
  if str == "0x00":
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

func vmConfiguration(network: string): VMConfig =
  case network
  of "EIP150": result = [(0, FkTangerine), (0, FkTangerine)]
  of "ConstantinopleFix": result = [(0, FkConstantinople), (0, FkConstantinople)]
  of "Homestead": result = [(0, FkHomestead), (0, FkHomestead)]
  of "Frontier": result = [(0, FkFrontier), (0, FkFrontier)]
  of "Byzantium": result = [(0, FkByzantium), (0, FkByzantium)]
  of "EIP158ToByzantiumAt5": result = [(0, FkSpurious), (5, FkByzantium)]
  of "EIP158": result = [(0, FkSpurious), (0, FkSpurious)]
  of "HomesteadToDaoAt5": result = [(0, FkHomestead), (5, FkHomestead)]
  of "Constantinople": result = [(0, FkConstantinople), (0, FkConstantinople)]
  of "HomesteadToEIP150At5": result = [(0, FkHomestead), (5, FkTangerine)]
  of "FrontierToHomesteadAt5": result = [(0, FkFrontier), (5, FkHomestead)]
  of "ByzantiumToConstantinopleFixAt5": result = [(0, FkByzantium), (5, FkConstantinople)]
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
  let network = fixture["network"].getStr
  result.vmConfig = vmConfiguration(network)

  try:
    result.blocks = parseBlocks(fixture["blocks"], testStatusIMPL)
  except ValueError:
    result.good = false

  # TODO: implement missing VM
  if network in ["Constantinople", "HomesteadToDaoAt5"]:
    result.good = false

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

proc processBlock(vmState: BaseVMState, minedBlock: PlainBlock, fork: Fork) =
  vmState.receipts = newSeq[Receipt](minedBlock.transactions.len)
  vmState.cumulativeGasUsed = 0

  for txIndex, tx in minedBlock.transactions:
    var sender: EthAddress
    if tx.getSender(sender):
      let gasUsed = processTransaction(tx, sender, vmState, fork)
    else:
      raise newException(ValidationError, "could not get sender")
    vmState.receipts[txIndex] = makeReceipt(vmState, fork)

  assignBlockRewards(minedBlock, vmState, fork, vmState.chainDB)

func validateBlockUnchanged(a, b: PlainBlock): bool =
  result = rlp.encode(a) == rlp.encode(b)

func validateBlock(blck: PlainBlock): bool =
  # TODO: implement block validation
  result = true

proc importBlock(chainDB: BaseChainDB, preminedBlock: PlainBlock, fork: Fork, validation = true): PlainBlock =
  let parentHeader = chainDB.getBlockHeader(preminedBlock.header.parentHash)
  let baseHeaderForImport = generateHeaderFromParentHeader(parentHeader,
      preminedBlock.header.coinbase, fork, some(preminedBlock.header.timestamp), @[])

  deepCopy(result, preminedBlock)
  var vmState = newBaseVMState(parentHeader.stateRoot, baseHeaderForImport, chainDB)
  processBlock(vmState, result, fork)

  deepCopy(result.header, vmState.blockHeader)

  if validation:
    if not validateBlockUnchanged(result, preminedBlock):
      raise newException(ValidationError, "block changed")
    if not validateBlock(result):
      raise newException(ValidationError, "invalid block")

  discard chainDB.persistHeaderToDb(preminedBlock.header)

proc applyFixtureBlockToChain(tb: TesterBlock,
  chainDB: BaseChainDB, fork: Fork, validation = true): (PlainBlock, PlainBlock, Blob) =
  var
    preminedBlock = rlp.decode(tb.headerRLP, PlainBlock)
    minedBlock = chainDB.importBlock(preminedBlock, fork, validation)
    rlpEncodedMinedBlock = rlp.encode(minedBlock)
  result = (preminedBlock, minedBlock, rlpEncodedMinedBlock)

proc runTester(tester: Tester, chainDB: BaseChainDB, testStatusIMPL: var TestStatus) =
  discard chainDB.persistHeaderToDb(tester.genesisBlockHeader)
  check chainDB.getCanonicalHead().blockHash == tester.genesisBlockHeader.blockHash

  for testerBlock in tester.blocks:
    let shouldBeGoodBlock = testerBlock.blockHeader.isSome

    if shouldBeGoodBlock:
      let blockNumber = testerBlock.blockHeader.get().blockNumber
      let fork = vmConfigToFork(tester.vmConfig, blockNumber)

      let (preminedBlock, minedBlock, blockRlp) = applyFixtureBlockToChain(
          testerBlock, chainDB, fork, validation = false)  # we manually validate below
      check validateBlock(preminedBlock) == true
   #else:
   #  try:
   #    apply_fixture_block_to_chain(block_fixture, chain)
   #  except (TypeError, rlp.DecodingError, rlp.DeserializationError, ValidationError) as err:
   #    # failure is expected on this bad block
   #    pass
   #  else:
   #    raise AssertionError("Block should have caused a validation error")

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus, debugMode = false) =
  # 1 - mine the genesis block
  # 2 - loop over blocks:
  #     - apply transactions
  #     - mine block
  # 3 - diff resulting state with expected state
  # 4 - check that all previous blocks were valid

  for fixtureName, fixture in node:
    var tester = parseTester(fixture, testStatusIMPL)
    var chainDB = newBaseChainDB(newMemoryDb(), false)

    echo "TESTING: ", fixtureName
    if not tester.good: continue

    var vmState = newBaseVMState(emptyRlpHash,
      tester.genesisBlockHeader, chainDB)

    vmState.mutateStateDB:
      setupStateDB(fixture["pre"], db)

    let obtainedHash = $(vmState.readOnlyStateDB.rootHash)
    check obtainedHash == $(tester.genesisBlockHeader.stateRoot)

    tester.debugMode = debugMode
    tester.runTester(chainDB, testStatusIMPL)

    #latest_block_hash = chain.get_canonical_block_by_number(chain.get_block().number - 1).hash
    #if latest_block_hash != fixture['lastblockhash']:
      #verifyStateDB(fixture["postState"], vmState.readOnlyStateDB)

proc main() =
  if paramCount() == 0:
    # run all test fixtures
    suite "block chain json tests":
      jsonTest("BlockchainTests", testFixture)
  else:
    # execute single test in debug mode
    let config = getConfiguration()
    if config.testSubject.len == 0:
      echo "missing test subject"
      quit(QuitFailure)

    let path = "tests" / "fixtures" / "BlockChainTests"
    let n = json.parseFile(path / config.testSubject)
    var testStatusIMPL: TestStatus
    testFixture(n, testStatusIMPL, debugMode = true)

when isMainModule:
  var message: string

  ## Processing command line arguments
  if processArguments(message) != Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

main()

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
