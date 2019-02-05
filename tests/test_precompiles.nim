# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, ../nimbus/vm/precompiles, json, byteutils, test_helpers, ospaths, tables,
  strformat, strutils, eth/trie/db, eth/common, ../nimbus/db/[db_chain, state_db],
  ../nimbus/[constants, vm_types, vm_state], ../nimbus/vm/[computation, message], macros

proc initAddress(i: byte): EthAddress = result[19] = i

template doTest(fixture: JsonNode, address: byte, action: untyped): untyped =
  for test in fixture:
    let
      blockNum = 1.u256 # TODO: Check other forks
      header = BlockHeader(blockNumber: blockNum)
      expected = test["expected"].getStr.hexToSeqByte
    var addressBytes = newSeq[byte](32)
    addressBytes[31] = address
    var
      dataStr = test["input"].getStr
      data = if dataStr.len > 0: dataStr.hexToSeqByte else: @[]
      vmState = newBaseVMState(header, newBaseChainDB(newMemoryDb()))
      gas = 1_000_000.GasInt
      gasPrice = 1.GasInt
      sender: EthAddress
      to = initAddress(address)
      message = newMessage(gas, gasPrice, to, sender, 0.u256, data, @[])
      computation = newBaseComputation(vmState, header.blockNumber, message)
    echo "Running ", action.astToStr, " - ", test["name"]
    `action`(computation)
    let c = computation.rawOutput == expected
    if not c: echo "Output  : " & computation.rawOutput.toHex & "\nExpected: " & expected.toHex
    check c

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  for label, child in fixtures:
    case toLowerAscii(label)
    of "ecrecover": child.doTest(paEcRecover.ord, ecRecover)
    of "sha256": child.doTest(paSha256.ord, sha256)
    of "ripemd": child.doTest(paRipeMd160.ord, ripemd160)
    of "identity": child.doTest(paIdentity.ord, identity)
    of "modexp": child.doTest(paModExp.ord, modexp)
    of "bn256add": child.doTest(paEcAdd.ord, bn256ECAdd)
    of "bn256mul": child.doTest(paEcMul.ord, bn256ECMul)
    of "ecpairing": child.doTest(paPairing.ord, bn256ecPairing)
    else:
      #raise newException(ValueError, "Unknown test vector '" & $label & "'")
      echo "Unknown test vector '" & $label & "'"

suite "Precompiles":
  jsonTest("PrecompileTests", testFixture)
