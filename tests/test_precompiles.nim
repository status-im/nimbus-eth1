# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, ../nimbus/vm_precompiles, json, stew/byteutils, test_helpers, os, tables,
  strformat, strutils, eth/trie/db, eth/common, ../nimbus/db/db_chain, ../nimbus/constants,
  ../nimbus/[vm_computation, vm_state, vm_types2], macros,
  test_allowed_to_fail,
  ../nimbus/transaction/call_evm, options

proc initAddress(i: byte): EthAddress = result[19] = i

template doTest(fixture: JsonNode, fork: Fork, address: PrecompileAddresses): untyped =
  for test in fixture:
    let
      blockNum = 1.u256 # TODO: Check other forks
      header = BlockHeader(blockNumber: blockNum)
      expectedErr = test.hasKey("ExpectedError")
      expected = if test.hasKey("Expected"): hexToSeqByte(test["Expected"].getStr) else: @[]
      dataStr = test["Input"].getStr
      vmState = newBaseVMState(header.stateRoot, header, newBaseChainDB(newMemoryDb()))
      gasExpected = if test.hasKey("Gas"): test["Gas"].getInt else: -1

    var call: RpcCallData
    call.source = ZERO_ADDRESS
    call.to = initAddress(address.byte)
    call.gas = 1_000_000_000.GasInt
    call.gasPrice = 1.GasInt
    call.value = 0.u256
    call.data = if dataStr.len > 0: dataStr.hexToSeqByte else: @[]
    call.contractCreation = false

    let fixtureResult = fixtureCallEvm(vmState, call, call.source, some(fork))

    if expectedErr:
      check fixtureResult.isError
    else:
      check not fixtureResult.isError
      let c = fixtureResult.output == expected
      if not c: echo "Output  : " & fixtureResult.output.toHex & "\nExpected: " & expected.toHex
      check c

      if gasExpected >= 0:
        if fixtureResult.gasUsed != gasExpected:
          debugEcho "GAS: ", fixtureResult.gasUsed, " ", gasExpected
        check fixtureResult.gasUsed == gasExpected

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  let
    label = fixtures["func"].getStr
    fork  = parseEnum[Fork](fixtures["fork"].getStr.toLowerAscii)
    data  = fixtures["data"]

  case toLowerAscii(label)
  of "ecrecover": data.doTest(fork, paEcRecover)
  of "sha256"   : data.doTest(fork, paSha256)
  of "ripemd"   : data.doTest(fork, paRipeMd160)
  of "identity" : data.doTest(fork, paIdentity)
  of "modexp"   : data.doTest(fork, paModExp)
  of "bn256add" : data.doTest(fork, paEcAdd)
  of "bn256mul" : data.doTest(fork, paEcMul)
  of "ecpairing": data.doTest(fork, paPairing)
  of "blake2f"  : data.doTest(fork, paBlake2bf)
  # EIP 2537: disabled
  # reason: not included in berlin
  #of "blsg1add" : data.doTest(fork, paBlsG1Add)
  #of "blsg1mul" : data.doTest(fork, paBlsG1Mul)
  #of "blsg1multiexp" : data.doTest(fork, paBlsG1MultiExp)
  #of "blsg2add" : data.doTest(fork, paBlsG2Add)
  #of "blsg2mul" : data.doTest(fork, paBlsG2Mul)
  #of "blsg2multiexp": data.doTest(fork, paBlsG2MultiExp)
  #of "blspairing": data.doTest(fork, paBlsPairing)
  #of "blsmapg1": data.doTest(fork, paBlsMapG1)
  #of "blsmapg2": data.doTest(fork, paBlsMapG2)
  else:
    echo "Unknown test vector '" & $label & "'"
    testStatusIMPL = SKIPPED

proc precompilesMain*() =
  suite "Precompiles":
    jsonTest("PrecompileTests", testFixture, skipPrecompilesTests)

when isMainModule:
  precompilesMain()
