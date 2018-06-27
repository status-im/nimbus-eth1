# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, strformat, strutils, sequtils, tables, json, ospaths, times,
  rlp, nimcrypto/[keccak, hash], eth_trie/[types, memdb], eth_common, ranges/typedranges,
  ./test_helpers,
  ../nimbus/[constants, errors, logging],
  ../nimbus/[vm_state, vm_types],
  ../nimbus/utils/[header, padding],
  ../nimbus/vm/interpreter,
  ../nimbus/db/[db_chain, state_db, backends/memory_backend]

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus)

suite "vm json tests":
  jsonTest("VMTests", testFixture)


proc stringFromBytes(x: ByteRange): string =
  result = newString(x.len)
  for i in 0 ..< x.len:
    result[i] = char(x[i])

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    break
  let fenv = fixture["env"]
  var emptyRlpHash = keccak256.digest(rlp.encode("").toOpenArray)
  let header = BlockHeader(
    coinbase: fenv{"currentCoinbase"}.getStr.parseAddress,
    difficulty: fenv{"currentDifficulty"}.getHexadecimalInt.u256,
    blockNumber: fenv{"currentNumber"}.getHexadecimalInt.u256,
    gasLimit: fenv{"currentGasLimit"}.getHexadecimalInt.GasInt,
    timestamp: fenv{"currentTimestamp"}.getHexadecimalInt.int64.fromUnix,
    stateRoot: emptyRlpHash
    )
  var memDb = newMemDB()
  var vm = newNimbusVM(header, newBaseChainDB(trieDB memDb))

  let fexec = fixture["exec"]
  var code = ""
  vm.state.mutateStateDB:
    setupStateDB(fixture{"pre"}, db)
    let address = fexec{"address"}.getStr.parseAddress
    code = stringFromBytes db.getCode(address)

  code = fexec{"code"}.getStr
  let message = newMessage(
      to = fexec{"address"}.getStr.parseAddress,
      sender = fexec{"caller"}.getStr.parseAddress,
      value = cast[uint](fexec{"value"}.getHexadecimalInt).u256, # Cast workaround for negative value
      data = fexec{"data"}.getStr.mapIt(it.byte),
      code = code,
      gas = fexec{"gas"}.getHexadecimalInt,
      gasPrice = fexec{"gasPrice"}.getHexadecimalInt,
      options = newMessageOptions(origin=fexec{"origin"}.getStr.parseAddress))

  #echo fixture{"exec"}
  var c = newCodeStreamFromUnescaped(code)
  if DEBUG:
    c.displayDecompiled()

  var computation = newBaseComputation(vm.state, message)
  computation.opcodes = OpLogic
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

    let expectedGasRemaining = fixture{"gas"}.getHexadecimalInt
    let actualGasRemaining = gasMeter.gasRemaining
    checkpoint(&"Remaining: {actualGasRemaining} - Expected: {expectedGasRemaining}")
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
      let toAddress = createdCall{"destination"}.getStr.parseAddress
      let data = createdCall{"data"}.getStr.mapIt(it.byte)
      let gasLimit = createdCall{"gasLimit"}.getHexadecimalInt
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
