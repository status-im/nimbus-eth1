# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, strformat, strutils, tables, json, ospaths, times,
  byteutils, ranges/typedranges, nimcrypto, options,
  eth/[rlp, common, keys], eth/trie/db, chronicles,
  ./test_helpers, ../nimbus/p2p/executor,
  ../nimbus/[constants, errors, transaction],
  ../nimbus/[vm_state, vm_types, vm_state_transactions, utils],
  ../nimbus/vm/interpreter,
  ../nimbus/db/[db_chain, state_db]

proc hashLogEntries(logs: seq[Log]): string =
  toLowerAscii("0x" & $keccak(rlp.encode(logs)))

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus)

suite "generalstate json tests":
  jsonTest("GeneralStateTests", testFixture)

proc testFixtureIndexes(prevStateRoot: Hash256, header: BlockHeader, pre: JsonNode, tx: Transaction,
                        expectedHash, expectedLogs: string, testStatusIMPL: var TestStatus, fork: Fork) =
  when enabledLogLevel <= TRACE:
    let tracerFlags = {TracerFlags.EnableTracing}
  else:
    let tracerFlags: set[TracerFlags] = {}
  var vmState = newBaseVMState(prevStateRoot, header, newBaseChainDB(newMemoryDb()), tracerFlags)
  vmState.mutateStateDB:
    setupStateDB(pre, db)

  defer:
    #echo vmState.readOnlyStateDB.dumpAccount("c94f5374fce5edbc8e2a8697c15331677e6ebf0b")
    let obtainedHash = "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii
    check obtainedHash == expectedHash
    let logEntries = vmState.getAndClearLogEntries()
    let actualLogsHash = hashLogEntries(logEntries)
    let expectedLogsHash = toLowerAscii(expectedLogs)
    check(expectedLogsHash == actualLogsHash)

  let sender = tx.getSender()
  if not validateTransaction(vmState, tx, sender):
    vmState.mutateStateDB:
      # pre-EIP158 (e.g., Byzantium) should ensure currentCoinbase exists
      # in later forks, don't create at all
      db.addBalance(header.coinbase, 0.u256)
    return

  vmState.mutateStateDB:
    let gasUsed = tx.processTransaction(sender, vmState, some(fork))
    db.addBalance(header.coinbase, gasUsed.u256 * tx.gasPrice.u256)

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    break

  let fenv = fixture["env"]
  var emptyRlpHash = keccak256.digest(rlp.encode(""))
  let header = BlockHeader(
    coinbase: fenv["currentCoinbase"].getStr.ethAddressFromHex,
    difficulty: fromHex(UInt256, fenv{"currentDifficulty"}.getStr),
    blockNumber: fenv{"currentNumber"}.getHexadecimalInt.u256,
    gasLimit: fenv{"currentGasLimit"}.getHexadecimalInt.GasInt,
    timestamp: fenv{"currentTimestamp"}.getHexadecimalInt.int64.fromUnix,
    stateRoot: emptyRlpHash
    )

  let ftrans = fixture["transaction"]
  for fork in supportedForks:
    if fixture["post"].hasKey(forkNames[fork]):
      # echo "[fork: ", forkNames[fork], "]"
      for expectation in fixture["post"][forkNames[fork]]:
        let
          expectedHash = expectation["hash"].getStr
          expectedLogs = expectation["logs"].getStr
          indexes = expectation["indexes"]
          dataIndex = indexes["data"].getInt
          gasIndex = indexes["gas"].getInt
          valueIndex = indexes["value"].getInt
        let transaction = ftrans.getFixtureTransaction(dataIndex, gasIndex, valueIndex)
        testFixtureIndexes(emptyRlpHash, header, fixture["pre"], transaction,
                           expectedHash, expectedLogs, testStatusIMPL, fork)
