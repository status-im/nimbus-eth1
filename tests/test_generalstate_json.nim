# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, strutils, tables, json, times, os, sets,
  nimcrypto, options,
  eth/[rlp, common], eth/trie/[db, trie_defs], chronicles,
  ./test_helpers, ./test_allowed_to_fail,
  ../nimbus/p2p/executor, test_config,
  ../nimbus/transaction,
  ../nimbus/[vm_state, vm_types, utils],
  ../nimbus/vm/interpreter,
  ../nimbus/db/[db_chain, accounts_cache]

type
  Tester = object
    name: string
    header: BlockHeader
    pre: JsonNode
    tx: Transaction
    expectedHash: string
    expectedLogs: string
    fork: Fork
    debugMode: bool
    trace: bool
    index: int

  GST_VMState = ref object of BaseVMState

proc toBytes(x: string): seq[byte] =
  result = newSeq[byte](x.len)
  for i in 0..<x.len: result[i] = x[i].byte

proc newGST_VMState(prevStateRoot: Hash256, header: BlockHeader, chainDB: BaseChainDB, tracerFlags: set[TracerFlags]): GST_VMState =
  new result
  result.init(prevStateRoot, header, chainDB, tracerFlags)

method getAncestorHash*(vmState: GST_VMState, blockNumber: BlockNumber): Hash256 {.gcsafe.} =
  if blockNumber >= vmState.blockNumber:
    return
  elif blockNumber < 0:
    return
  elif blockNumber < vmState.blockNumber - 256:
    return
  else:
    return keccakHash(toBytes($blockNumber))

proc dumpAccount(accountDb: ReadOnlyStateDB, address: EthAddress, name: string): JsonNode =
  result = %{
    "name": %name,
    "address": %($address),
    "nonce": %toHex(accountDb.getNonce(address)),
    "balance": %accountDb.getBalance(address).toHex(),
    "codehash": %($accountDb.getCodeHash(address)),
    "storageRoot": %($accountDb.getStorageRoot(address))
  }

proc dumpDebugData(tester: Tester, vmState: BaseVMState, sender: EthAddress, gasUsed: GasInt, success: bool) =
  let recipient = tester.tx.getRecipient()
  let miner = tester.header.coinbase
  var accounts = newJObject()

  accounts[$miner] = dumpAccount(vmState.readOnlyStateDB, miner, "miner")
  accounts[$sender] = dumpAccount(vmState.readOnlyStateDB, sender, "sender")
  accounts[$recipient] = dumpAccount(vmState.readOnlyStateDB, recipient, "recipient")

  let accountList = [sender, miner, recipient]
  var i = 0
  for ac, _ in tester.pre:
    let account = ethAddressFromHex(ac)
    if account notin accountList:
      accounts[$account] = dumpAccount(vmState.readOnlyStateDB, account, "pre" & $i)
      inc i

  let tracingResult = if tester.trace: vmState.getTracingResult() else: %[]
  let debugData = %{
    "gasUsed": %gasUsed,
    "structLogs": tracingResult,
    "accounts": accounts
  }
  let status = if success: "_success" else: "_failed"
  writeFile("debug_" & tester.name & "_" & $tester.index & status & ".json", debugData.pretty())

proc testFixtureIndexes(tester: Tester, testStatusIMPL: var TestStatus) =
  var tracerFlags: set[TracerFlags] = if tester.trace: {TracerFlags.EnableTracing} else : {}

  var chainDB = newBaseChainDB(newMemoryDb(), pruneTrie = getConfiguration().pruning)
  var vmState = newGST_VMState(emptyRlpHash, tester.header, chainDB, tracerFlags)
  var gasUsed: GasInt
  let sender = tester.tx.getSender()

  vmState.mutateStateDB:
    setupStateDB(tester.pre, db)

    # this is an important step when using accounts_cache
    # it will affect the account storage's location
    # during the next call to `getComittedStorage`
    db.persist()

  defer:
    let obtainedHash = "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii
    check obtainedHash == tester.expectedHash
    let logEntries = vmState.getAndClearLogEntries()
    let actualLogsHash = hashLogEntries(logEntries)
    let expectedLogsHash = toLowerAscii(tester.expectedLogs)
    check(expectedLogsHash == actualLogsHash)
    if tester.debugMode:
      let success = expectedLogsHash == actualLogsHash and obtainedHash == tester.expectedHash
      tester.dumpDebugData(vmState, sender, gasUsed, success)

  gasUsed = tester.tx.processTransaction(sender, vmState, tester.fork)

  # This is necessary due to the manner in which the state tests are
  # generated. State tests are generated from the BlockChainTest tests
  # in which these transactions are included in the larger context of a
  # block and thus, the mechanisms which would touch/create/clear the
  # coinbase account based on the mining reward are present during test
  # generation, but not part of the execution, thus we must artificially
  # create the account in VMs prior to the state clearing rules,
  # as well as conditionally cleaning up the coinbase account when left
  # empty in VMs after the state clearing rules came into effect.
  let miner = tester.header.coinbase
  if miner in vmState.suicides:
    vmState.mutateStateDB:
      db.addBalance(miner, 0.u256)
      if tester.fork >= FkSpurious:
        if db.isEmptyAccount(miner):
          db.deleteAccount(miner)

      # this is an important step when using accounts_cache
      # it will affect the account storage's location
      # during the next call to `getComittedStorage`
      # and the result of rootHash
      db.persist()

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus,
                 trace = false, debugMode = false, supportedForks: set[Fork] = supportedForks) =
  var tester: Tester
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    tester.name = label
    break

  let fenv = fixture["env"]
  tester.header = BlockHeader(
    coinbase: fenv["currentCoinbase"].getStr.ethAddressFromHex,
    difficulty: fromHex(UInt256, fenv{"currentDifficulty"}.getStr),
    blockNumber: fenv{"currentNumber"}.getHexadecimalInt.u256,
    gasLimit: fenv{"currentGasLimit"}.getHexadecimalInt.GasInt,
    timestamp: fenv{"currentTimestamp"}.getHexadecimalInt.int64.fromUnix,
    stateRoot: emptyRlpHash
    )

  let specifyIndex = getConfiguration().index
  tester.trace = trace
  tester.debugMode = debugMode
  let ftrans = fixture["transaction"]
  var testedInFork = false
  var numIndex = -1
  for fork in supportedForks:
    if fixture["post"].hasKey(forkNames[fork]):
      numIndex = fixture["post"][forkNames[fork]].len
      for expectation in fixture["post"][forkNames[fork]]:
        inc tester.index
        if specifyIndex > 0 and tester.index != specifyIndex:
          continue
        testedInFork = true
        tester.expectedHash = expectation["hash"].getStr
        tester.expectedLogs = expectation["logs"].getStr
        let
          indexes = expectation["indexes"]
          dataIndex = indexes["data"].getInt
          gasIndex = indexes["gas"].getInt
          valueIndex = indexes["value"].getInt
        tester.tx = ftrans.getFixtureTransaction(dataIndex, gasIndex, valueIndex)
        tester.pre = fixture["pre"]
        tester.fork = fork
        testFixtureIndexes(tester, testStatusIMPL)

  if not testedInFork:
    echo "test subject '", tester.name, "' not tested in any forks/subtests"
    if specifyIndex <= 0 or specifyIndex > numIndex:
      echo "Maximum subtest available: ", numIndex
    else:
      echo "available forks in this test:"
      for fork in test_helpers.supportedForks:
        if fixture["post"].hasKey(forkNames[fork]):
          echo fork

proc generalStateJsonMain*(debugMode = false) =
  if paramCount() == 0 or not debugMode:
    # run all test fixtures
    suite "generalstate json tests":
      jsonTest("GeneralStateTests", testFixture, skipGSTTests)
    suite "new generalstate json tests":
      jsonTest("newGeneralStateTests", testFixture, skipNewGSTTests)
  else:
    # execute single test in debug mode
    let config = getConfiguration()
    if config.testSubject.len == 0:
      echo "missing test subject"
      quit(QuitFailure)

    let folder = if config.legacy: "GeneralStateTests" else: "newGeneralStateTests"
    let path = "tests" / "fixtures" / folder
    let n = json.parseFile(path / config.testSubject)
    var testStatusIMPL: TestStatus
    var forks: set[Fork] = {}
    forks.incl config.fork
    testFixture(n, testStatusIMPL, config.trace, true, forks)

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
  generalStateJsonMain(true)
