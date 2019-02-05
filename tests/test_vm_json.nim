# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, strformat, strutils, sequtils, tables, json, ospaths, times,
  byteutils, ranges/typedranges, nimcrypto/[keccak, hash],
  eth/[rlp, common], eth/trie/db,
  ./test_helpers,
  ../nimbus/[constants, errors],
  ../nimbus/[vm_state, vm_types],
  ../nimbus/utils/header,
  ../nimbus/vm/interpreter,
  ../nimbus/db/[db_chain, state_db]

proc hashLogEntries(logs: seq[Log]): string =
  toLowerAscii("0x" & $keccak256.digest(rlp.encode(logs)))

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus)

suite "vm json tests":
  jsonTest("VMTests", testFixture)


proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    break

  let fenv = fixture["env"]
  var emptyRlpHash = keccak256.digest(rlp.encode(""))
  let header = BlockHeader(
    coinbase: fenv{"currentCoinbase"}.getStr.parseAddress,
    difficulty: fromHex(UInt256, fenv{"currentDifficulty"}.getStr),
    blockNumber: fenv{"currentNumber"}.getHexadecimalInt.u256,
    gasLimit: fenv{"currentGasLimit"}.getHexadecimalInt.GasInt,
    timestamp: fenv{"currentTimestamp"}.getHexadecimalInt.int64.fromUnix,
    stateRoot: emptyRlpHash
    )

  var vmState = newBaseVMState(header, newBaseChainDB(newMemoryDB()))
  let fexec = fixture["exec"]
  var code: seq[byte]
  vmState.mutateStateDB:
    setupStateDB(fixture{"pre"}, db)
    let address = fexec{"address"}.getStr.parseAddress
    code = db.getCode(address).toSeq

  code = fexec{"code"}.getStr.hexToSeqByte
  let toAddress = fexec{"address"}.getStr.parseAddress
  let message = newMessage(
      to = toAddress,
      sender = fexec{"caller"}.getStr.parseAddress,
      value = cast[uint64](fexec{"value"}.getHexadecimalInt).u256, # Cast workaround for negative value
      data = fexec{"data"}.getStr.hexToSeqByte,
      code = code,
      gas = fexec{"gas"}.getHexadecimalInt,
      gasPrice = fexec{"gasPrice"}.getHexadecimalInt,
      options = newMessageOptions(origin=fexec{"origin"}.getStr.parseAddress,
                                  createAddress = toAddress))

  var computation = newBaseComputation(vmState, header.blockNumber, message)
  computation.executeOpcodes()

  if not fixture{"post"}.isNil:
    # Success checks
    check(not computation.isError)
    if computation.isError:
      echo "Computation error: ", computation.error.info

    let logEntries = vmState.getAndClearLogEntries()
    if not fixture{"logs"}.isNil:
      let actualLogsHash = hashLogEntries(logEntries)
      let expectedLogsHash = toLowerAscii(fixture{"logs"}.getStr)
      check(expectedLogsHash == actualLogsHash)
    elif logEntries.len > 0:
      checkpoint(&"Got log entries: {logEntries}")
      fail()

    let expectedOutput = fixture{"out"}.getStr
    check(computation.outputHex == expectedOutput)
    let gasMeter = computation.gasMeter

    let expectedGasRemaining = fixture{"gas"}.getHexadecimalInt
    let actualGasRemaining = gasMeter.gasRemaining
    checkpoint(&"Remaining: {actualGasRemaining} - Expected: {expectedGasRemaining}")
    check(actualGasRemaining == expectedGasRemaining or
          computation.code.hasSStore() and
            (actualGasRemaining > expectedGasRemaining and (actualGasRemaining - expectedGasRemaining) mod 15_000 == 0 or
             expectedGasRemaining > actualGasRemaining and (expectedGasRemaining - actualGasRemaining) mod 15_000 == 0))

    if not fixture{"post"}.isNil:
      verifyStateDb(fixture{"post"}, computation.vmState.readOnlyStateDB)
  else:
      # Error checks
      check(computation.isError)
      # TODO postState = fixture{"pre"}

