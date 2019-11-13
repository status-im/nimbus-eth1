# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, ../nimbus/vm/precompiles, json, stew/byteutils, test_helpers, os, tables,
  strformat, strutils, eth/trie/db, eth/common, ../nimbus/db/db_chain,
  ../nimbus/[vm_types, vm_state], ../nimbus/vm/[computation, message], macros,
  ../nimbus/vm/blake2b_f

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
      vmState = newBaseVMState(header.stateRoot, header, newBaseChainDB(newMemoryDb()))
      gas = 1_000_000.GasInt
      gasPrice = 1.GasInt
      sender: EthAddress
      to = initAddress(address)
      message = newMessage(gas, gasPrice, to, sender, 0.u256, data, @[], contractCreation = false)
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

const blake2InputTests = [
  (
    input:    "",
    expected: "error",
    name:     "vector 0: empty input",
  ),
  (
    input:    "00000c48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001",
    expected: "error",
    name:     "vector 1: less than 213 bytes input",
  ),
  (
    input:    "000000000c48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001",
    expected: "error",
    name:     "vector 2: more than 213 bytes input",
  ),
  (
    input:    "0000000c48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000002",
    expected: "error",
    name:     "vector 3: malformed final block indicator flag",
  ),
  (
    input:    "0000000048c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001",
    expected: "08c9bcf367e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d282e6ad7f520e511f6c3e2b8c68059b9442be0454267ce079217e1319cde05b",
    name:     "vector 4",
  ),
  (
    input:    "0000000c48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001",
    expected: "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923",
    name:     "vector 5",
  ),
  (
    input:    "0000000c48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000",
    expected: "75ab69d3190a562c51aef8d88f1c2775876944407270c42c9844252c26d2875298743e7f6d5ea2f2d3e8d226039cd31b4e426ac4f2d3d666a610c2116fde4735",
    name:     "vector 6",
  ),
  (
    input:    "0000000148c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001",
    expected: "b63a380cb2897d521994a85234ee2c181b5f844d2c624c002677e9703449d2fba551b3a8333bcdf5f2f7e08993d53923de3d64fcc68c034e717b9293fed7a421",
    name:     "vector 7",
  ),
  (
    input:    "007A120048c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001",
    expected: "6d2ce9e534d50e18ff866ae92d70cceba79bbcd14c63819fe48752c8aca87a4bb7dcc230d22a4047f0486cfcfb50a17b24b2899eb8fca370f22240adb5170189",
    name:     "vector 8",
  ),
]

proc precompilesMain*() =
  suite "Precompiles":
    jsonTest("PrecompileTests", testFixture)

  suite "blake2bf":
    var output: array[64, byte]
    var expectedOutput: array[64, byte]
    for x in blake2InputTests:
      test x.name:
        let z = if x.input.len == 0: @[] else: hexToSeqByte(x.input)
        let res = blake2b_F(z, output)
        if x.expected == "error":
          check res == false
        else:
          hexToByteArray(x.expected, expectedOutput)
          check res == true
          check expectedOutput == output

when isMainModule:
  precompilesMain()
