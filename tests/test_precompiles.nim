# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[strformat, strutils, json, os, tables, macros],
  unittest2, stew/byteutils,
  eth/[keys, trie],
  ../nimbus/common/common,
  ../nimbus/[vm_computation,
    vm_state,
    vm_types,
    constants,
    vm_precompiles,
    transaction,
    transaction/call_evm
    ],

  ./test_helpers, ./test_allowed_to_fail

proc initAddress(i: byte): EthAddress = result[19] = i

template doTest(fixture: JsonNode; vmState: BaseVMState; fork: EVMFork, address: PrecompileAddresses): untyped =
  for test in fixture:
    let
      expectedErr = test.hasKey("ExpectedError")
      expected = if test.hasKey("Expected"): hexToSeqByte(test["Expected"].getStr) else: @[]
      dataStr = test["Input"].getStr
      gasExpected = if test.hasKey("Gas"): test["Gas"].getInt else: -1

    let unsignedTx = Transaction(
      txType: TxLegacy,
      nonce: 0,
      gasPrice: 1.GasInt,
      gasLimit: 1_000_000_000.GasInt,
      to: initAddress(address.byte).some,
      value: 0.u256,
      payload: if dataStr.len > 0: dataStr.hexToSeqByte else: @[]
    )
    let tx = signTransaction(unsignedTx, privateKey, ChainId(1), false)
    let fixtureResult = testCallEvm(tx, tx.getSender, vmState, fork)

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

proc parseFork(x: string): EVMFork =
  let x = x.toLowerAscii
  for name, fork in nameToFork:
    if name.toLowerAscii == x:
      return fork
  doAssert(false, "unsupported fork name " & x)

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  let
    label = fixtures["func"].getStr
    fork  = parseFork(fixtures["fork"].getStr)
    data  = fixtures["data"]
    privateKey = PrivateKey.fromHex("7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d")[]
    com = CommonRef.new(newCoreDbRef DefaultDbMemory, config = ChainConfig())
    vmState = BaseVMState.new(
      BlockHeader(blockNumber: 1.u256, stateRoot: emptyRlpHash),
      BlockHeader(),
      com
    )

  case toLowerAscii(label)
  of "ecrecover": data.doTest(vmState, fork, paEcRecover)
  of "sha256"   : data.doTest(vmState, fork, paSha256)
  of "ripemd"   : data.doTest(vmState, fork, paRipeMd160)
  of "identity" : data.doTest(vmState, fork, paIdentity)
  of "modexp"   : data.doTest(vmState, fork, paModExp)
  of "bn256add" : data.doTest(vmState, fork, paEcAdd)
  of "bn256mul" : data.doTest(vmState, fork, paEcMul)
  of "ecpairing": data.doTest(vmState, fork, paPairing)
  of "blake2f"  : data.doTest(vmState, fork, paBlake2bf)
  # EIP 2537: disabled
  # reason: not included in berlin
  #of "blsg1add" : data.doTest(vmState, fork, paBlsG1Add)
  #of "blsg1mul" : data.doTest(vmState, fork, paBlsG1Mul)
  #of "blsg1multiexp" : data.doTest(vmState, fork, paBlsG1MultiExp)
  #of "blsg2add" : data.doTest(vmState, fork, paBlsG2Add)
  #of "blsg2mul" : data.doTest(vmState, fork, paBlsG2Mul)
  #of "blsg2multiexp": data.doTest(vmState, fork, paBlsG2MultiExp)
  #of "blspairing": data.doTest(vmState, fork, paBlsPairing)
  #of "blsmapg1": data.doTest(vmState, fork, paBlsMapG1)
  #of "blsmapg2": data.doTest(vmState, fork, paBlsMapG2)
  else:
    echo "Unknown test vector '" & $label & "'"
    testStatusIMPL = SKIPPED

proc precompilesMain*() =
  suite "Precompiles":
    jsonTest("PrecompileTests", testFixture, skipPrecompilesTests)

when isMainModule:
  precompilesMain()
