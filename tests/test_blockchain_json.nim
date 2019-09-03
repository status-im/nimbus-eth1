# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, json, os, tables, strutils, sets, strformat,
  options,
  eth/[common, rlp], eth/trie/[db, trie_defs],
  ./test_helpers, ../premix/parser,
  ../nimbus/vm/interpreter/vm_forks,
  ../nimbus/[vm_state, utils],
  ../nimbus/db/[db_chain, state_db]

type
  SealEngine = enum
    NoProof
    Ethash

  TesterBlock = object
    blockHeader: Option[BlockHeader]
    rlp: Blob
    transactions: seq[Transaction]
    uncles: seq[BlockHeader]
    blockNumber: Option[int]
    chainName: Option[string]
    chainNetwork: Option[Fork]
    exceptions: seq[(string, string)]

  Tester = object
    name: string
    lastBlockHash: Hash256
    genesisBlockHeader: BlockHeader
    blocks: seq[TesterBlock]
    sealEngine: Option[SealEngine]
    network: string

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus)

#[var topLevel = initCountTable[string]()

suite "block chain json tests":
  jsonTest("BlockchainTests", testFixture)
  topLevel.sort
  for k, v in topLevel:
    echo k, " ", v

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus) =
  for name, klm in node:
    for k, value in klm:
      if k == "blocks":
        for bc in value:
          for key, val in bc:
            if key == "transactions":
              for tx in val:
                for tk, tv in tx:
                  topLevel.inc tk
]#

suite "block chain json tests":
  jsonTest("BlockchainTests", testFixture)

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
        # var headerRLP: Blob
        # fixture.fromJson "rlp", headerRLP
        # check rlp.encode(t.blockHeader.get()) == headerRLP
        discard
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

proc runTester(t: Tester, testStatusIMPL: var TestStatus) =
  discard

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus) =
  var t: Tester
  for fixtureName, fixture in node:
    t.name = fixtureName
    echo "TESTING: ", fixtureName
    fixture.fromJson "lastblockhash", t.lastBlockHash
    t.genesisBlockHeader = parseHeader(fixture["genesisBlockHeader"], testStatusIMPL)

    # none of the fixtures pass this test
    #if "genesisRLP" in fixture:
    #  var genesisRLP: Blob
    #  fixture.fromJson "genesisRLP", genesisRLP
    #  check genesisRLP == rlp.encode(t.genesisBlockHeader)

    if "sealEngine" in fixture:
      t.sealEngine = some(parseEnum[SealEngine](fixture["sealEngine"].getStr))
    t.network = fixture["network"].getStr
    t.blocks = parseBlocks(fixture["blocks"], testStatusIMPL)

    var vmState = newBaseVMState(emptyRlpHash,
      t.genesisBlockHeader, newBaseChainDB(newMemoryDb()))

    vmState.mutateStateDB:
      setupStateDB(fixture["pre"], db)

    let obtainedHash = $(vmState.readOnlyStateDB.rootHash)
    check obtainedHash == $(t.genesisBlockHeader.stateRoot)

    t.runTester(testStatusIMPL)
    #verifyStateDB(fixture["postState"], vmState.readOnlyStateDB)

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
