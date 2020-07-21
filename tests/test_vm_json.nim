# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, strformat, strutils, tables, json, os, times, sequtils,
  stew/byteutils, eth/[rlp, common], eth/trie/db,
  ./test_helpers, ./test_allowed_to_fail, ../nimbus/vm/interpreter,
  ../nimbus/[constants, vm_state, vm_types, utils],
  ../nimbus/db/[db_chain]

func bytesToHex(x: openarray[byte]): string {.inline.} =
  ## TODO: use seq[byte] for raw data and delete this proc
  foldl(x, a & b.int.toHex(2).toLowerAscii, "0x")

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus)

proc vmJsonMain*() =
  suite "vm json tests":
    jsonTest("VMTests", testFixture, skipVMTests)

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    break

  let fenv = fixture["env"]
  var emptyRlpHash = keccakHash(rlp.encode(""))
  let header = BlockHeader(
    coinbase: fenv{"currentCoinbase"}.getStr.parseAddress,
    difficulty: fromHex(UInt256, fenv{"currentDifficulty"}.getStr),
    blockNumber: fenv{"currentNumber"}.getHexadecimalInt.u256,
    gasLimit: fenv{"currentGasLimit"}.getHexadecimalInt.GasInt,
    timestamp: fenv{"currentTimestamp"}.getHexadecimalInt.int64.fromUnix,
    stateRoot: emptyRlpHash
    )

  var vmState = newBaseVMState(emptyRlpHash, header, newBaseChainDB(newMemoryDB()))
  let fexec = fixture["exec"]
  vmState.mutateStateDB:
    setupStateDB(fixture{"pre"}, db)

  vmState.setupTxContext(
    origin = fexec{"origin"}.getStr.parseAddress,
    gasPrice = fexec{"gasPrice"}.getHexadecimalInt
  )

  let toAddress = fexec{"address"}.getStr.parseAddress
  let message = Message(
    kind: if toAddress == ZERO_ADDRESS: evmcCreate else: evmcCall, # assume ZERO_ADDRESS is a contract creation
    depth: 0,
    gas: fexec{"gas"}.getHexadecimalInt,
    sender: fexec{"caller"}.getStr.parseAddress,
    contractAddress: toAddress,
    codeAddress: toAddress,
    value: cast[uint64](fexec{"value"}.getHexadecimalInt).u256, # Cast workaround for negative value
    data: fexec{"data"}.getStr.hexToSeqByte
    )

  var computation = newComputation(vmState, message)
  computation.executeOpcodes()

  if not fixture{"post"}.isNil:
    # Success checks
    check(not computation.isError)
    if computation.isError:
      echo "Computation error: ", computation.error.info

    let logEntries = computation.logEntries
    if not fixture{"logs"}.isNil:
      let actualLogsHash = hashLogEntries(logEntries)
      let expectedLogsHash = toLowerAscii(fixture{"logs"}.getStr)
      check(expectedLogsHash == actualLogsHash)
    elif logEntries.len > 0:
      checkpoint(&"Got log entries: {logEntries}")
      fail()

    let expectedOutput = fixture{"out"}.getStr
    check(computation.output.bytesToHex == expectedOutput)
    let gasMeter = computation.gasMeter

    let expectedGasRemaining = fixture{"gas"}.getHexadecimalInt
    let actualGasRemaining = gasMeter.gasRemaining
    checkpoint(&"Remaining: {actualGasRemaining} - Expected: {expectedGasRemaining}")
    check(actualGasRemaining == expectedGasRemaining)

    if not fixture{"post"}.isNil:
      verifyStateDb(fixture{"post"}, computation.vmState.readOnlyStateDB)
  else:
    # Error checks
    check(computation.isError)
    if not fixture{"pre"}.isNil:
      verifyStateDb(fixture{"pre"}, computation.vmState.readOnlyStateDB)

when isMainModule:
  vmJsonMain()
