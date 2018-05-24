# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, strformat, strutils, sequtils, tables, stint, json, ospaths, times,
  ./test_helpers,
  ../src/[constants, errors, logging],
  ../src/[chain, vm_state, computation, opcode, types, opcode_table],
  ../src/utils/[header, padding],
  ../src/vm/[gas_meter, message, code_stream, stack],
  ../src/vm/forks/vm_forks, ../src/db/[db_chain, state_db, backends/memory_backend]

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus)

suite "vm json tests":
  jsonTest("VMTests", testFixture)

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    break
  let header = BlockHeader(
    coinbase: fixture{"env"}{"currentCoinbase"}.getStr,
    difficulty: fixture{"env"}{"currentDifficulty"}.getHexadecimalInt.u256,
    blockNumber: fixture{"env"}{"currentNumber"}.getHexadecimalInt.u256,
    # gasLimit: fixture{"env"}{"currentGasLimit"}.getHexadecimalInt.u256,
    timestamp: fixture{"env"}{"currentTimestamp"}.getHexadecimalInt.int64.fromUnix
    )
  var vm = newNimbusVM(header, newBaseChainDB(newMemoryDB()))

  var code = ""
  vm.state.db(readOnly=false):
    setupStateDB(fixture{"pre"}, db)
    code = db.getCode(fixture{"exec"}{"address"}.getStr)

  code = fixture{"exec"}{"code"}.getStr
  let message = newMessage(
      to=fixture{"exec"}{"address"}.getStr,
      sender=fixture{"exec"}{"caller"}.getStr,
      value=fixture{"exec"}{"value"}.getHexadecimalInt.u256,
      data=fixture{"exec"}{"data"}.getStr.mapIt(it.byte),
      code=code,
      gas=fixture{"exec"}{"gas"}.getHexadecimalInt.u256,
      gasPrice=fixture{"exec"}{"gasPrice"}.getHexadecimalInt.u256,
      options=newMessageOptions(origin=fixture{"exec"}{"origin"}.getStr))

  #echo fixture{"exec"}
  var c = newCodeStreamFromUnescaped(code)
  if DEBUG:
    c.displayDecompiled()

  var computation = newBaseComputation(vm.state, message)
  computation.accountsToDelete = initTable[string, string]()
  computation.opcodes = OPCODE_TABLE
  computation.precompiles = initTable[string, Opcode]()

  computation = computation.applyComputation(vm.state, message)

  if not fixture{"post"}.isNil:
    # Success checks
    check(not computation.isError)
    if computation.isError:
      echo "Computation error: ", computation.error.info

    let logEntries = computation.getLogEntries()
    if not fixture{"logs"}.isNil:
      discard
      # TODO hashLogEntries let actualLogsHash = hashLogEntries(logEntries)
      # let expectedLogsHash = fixture{"logs"}.getStr
      # check(expectedLogsHash == actualLogsHash)
    elif logEntries.len > 0:
      checkpoint(&"Got log entries: {logEntries}")
      fail()

    let expectedOutput = fixture{"out"}.getStr
    check(computation.output == expectedOutput)
    let gasMeter = computation.gasMeter

    let expectedGasRemaining = fixture{"gas"}.getHexadecimalInt.u256
    let actualGasRemaining = gasMeter.gasRemaining
    checkpoint(&"{actualGasRemaining} {expectedGasRemaining}")
    check(actualGasRemaining == expectedGasRemaining or
          computation.code.hasSStore() and
            (actualGasRemaining > expectedGasRemaining and (actualGasRemaining - expectedGasRemaining) mod 15_000 == 0 or
             expectedGasRemaining > actualGasRemaining and (expectedGasRemaining - actualGasRemaining) mod 15_000 == 0))

    let callCreatesJson = fixture{"callcreates"}
    var callCreates: seq[JsonNode] = @[]
    if not callCreatesJson.isNil:
      for next in callCreatesJson:
        callCreates.add(next)

    check(computation.children.len == callCreates.len)
    for child in zip(computation.children, callCreates):
      var (childComputation, createdCall) = child
      let toAddress = createdCall{"destination"}.getStr
      let data = createdCall{"data"}.getStr.mapIt(it.byte)
      let gasLimit = createdCall{"gasLimit"}.getHexadecimalInt.u256
      let value = createdCall{"value"}.getHexadecimalInt.u256

      check(childComputation.msg.to == toAddress)
      check(data == childComputation.msg.data or childComputation.msg.code.len > 0)
      check(gasLimit == childComputation.msg.gas)
      check(value == childComputation.msg.value)
      # TODO postState = fixture{"post"}
  else:
      # Error checks
      check(computation.isError)
      # TODO postState = fixture{"pre"}

  # TODO with vm.state.stateDb(readOnly=True) as stateDb:
  #    verifyStateDb(postState, stateDb)
