import
  unittest, strformat, strutils, sequtils, tables, ttmath, json,
  helpers, constants, errors, logging,
  chain, vm_state, computation, opcode, utils / header, vm / [gas_meter, message, code_stream], vm / forks / frontier / vm, db / [db_chain, state_db], db / backends / memory_backend


proc testFixture(fixture: JsonNode)

suite "vm json tests":
  jsonTest("VMTests", testFixture)

proc testFixture(fixture: JsonNode) =
  var vm = newFrontierVM(Header(), newBaseChainDB(newMemoryDB()))
  let header = Header(
    coinbase: fixture{"env"}{"currentCoinbase"}.getStr,
    difficulty: fixture{"env"}{"currentDifficulty"}.getInt.i256,
    blockNumber: fixture{"env"}{"currentNumber"}.getInt.i256,
    gasLimit: fixture{"env"}{"currentGasLimit"}.getInt.i256,
    timestamp: fixture{"env"}{"currentTimestamp"}.getInt)
  
  var code = ""
  vm.state.db(readOnly=false):
    setupStateDB(fixture{"pre"}, db)
    code = db.getCode(fixture{"exec"}{"address"}.getStr)

  let message = newMessage(
      to=fixture{"exec"}{"address"}.getStr,
      sender=fixture{"exec"}{"caller"}.getStr,
      value=fixture{"exec"}{"value"}.getInt.i256,
      data=fixture{"exec"}{"data"}.getStr.mapIt(it.byte),
      code=code,
      gas=fixture{"exec"}{"gas"}.getInt.i256,
      gasPrice=fixture{"exec"}{"gasPrice"}.getInt.i256,
      options=newMessageOptions(origin=fixture{"exec"}{"origin"}.getStr))
  let computation = newBaseComputation(vm.state, message).applyComputation(vm.state, message)

  if not fixture{"post"}.isNil:
    # Success checks
    check(not computation.isError)

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

    let expectedGasRemaining = fixture{"gas"}.getInt.i256
    let actualGasRemaining = gasMeter.gasRemaining
    let gasDelta = actualGasRemaining - expectedGasRemaining
    check(gasDelta == 0)

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
      let gasLimit = createdCall{"gasLimit"}.getInt.i256
      let value = createdCall{"value"}.getInt.i256

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
