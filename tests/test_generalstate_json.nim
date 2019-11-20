# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, strformat, strutils, tables, json, times, os,
  stew/ranges/typedranges, nimcrypto, options,
  eth/[rlp, common], eth/trie/[db, trie_defs], chronicles,
  ./test_helpers, ./test_allowed_to_fail,
  ../nimbus/p2p/executor, test_config,
  ../nimbus/transaction,
  ../nimbus/[vm_state, vm_types, vm_state_transactions, utils],
  ../nimbus/vm/interpreter,
  ../nimbus/db/[db_chain, state_db]

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
  # TODO: implement journalDB in AccountStateDB
  # then turn on state trie pruning
  var vmState = newGST_VMState(emptyRlpHash, tester.header, newBaseChainDB(newMemoryDb(), false), tracerFlags)
  var gasUsed: GasInt
  let sender = tester.tx.getSender()

  vmState.mutateStateDB:
    setupStateDB(tester.pre, db)

  vmState.accountDB.updateOriginalRoot()

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

  if not validateTransaction(vmState, tester.tx, sender, tester.fork):
    vmState.mutateStateDB:
      # pre-EIP158 (e.g., Byzantium) should ensure currentCoinbase exists
      # in later forks, don't create at all
      db.addBalance(tester.header.coinbase, 0.u256)

      # TODO: this feels not right to be here
      # perhaps the entire validateTransaction block
      # should be moved into processTransaction
      if tester.fork >= FkSpurious:
        let miner = tester.header.coinbase
        let touchedAccounts = [miner]
        for account in touchedAccounts:
          debug "state clearing", account
          if db.accountExists(account) and db.isEmptyAccount(account):
            db.deleteAccount(account)

    return

  gasUsed = tester.tx.processTransaction(sender, vmState, tester.fork)

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
  for fork in supportedForks:
    if fixture["post"].hasKey(forkNames[fork]):
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
    echo "test subject '", tester.name, "' not tested in any forks"

proc generalStateJsonMain*(debugMode = false) =
  if paramCount() == 0 or not debugMode:
    # run all test fixtures
    #suite "generalstate json tests":
      #jsonTest("GeneralStateTests", testFixture, skipGSTTests)
    suite "new generalstate json tests":
      jsonTest("newGeneralStateTests", testFixture, skipNewGSTTests)
  else:
    # execute single test in debug mode
    let config = getConfiguration()
    if config.testSubject.len == 0:
      echo "missing test subject"
      quit(QuitFailure)

    let path = "tests" / "fixtures" / "newGeneralStateTests"
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
