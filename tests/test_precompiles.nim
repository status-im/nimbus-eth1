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
  ../tools/common/helpers as chp,
  ../nimbus/[evm/computation,
    evm/state,
    evm/types,
    constants,
    evm/precompiles {.all.},
    transaction,
    transaction/call_evm
    ],

  ./test_helpers, ./test_allowed_to_fail

proc initAddress(i: byte): EthAddress = result.data[19] = i

template doTest(fixture: JsonNode; vmState: BaseVMState; address: PrecompileAddresses): untyped =
  for test in fixture:
    let
      expectedErr = test.hasKey("ExpectedError")
      expected = if test.hasKey("Expected"): hexToSeqByte(test["Expected"].getStr) else: @[]
      dataStr = test["Input"].getStr
      gasExpected = if test.hasKey("Gas"):
                      Opt.some(GasInt test["Gas"].getInt)
                    else:
                      Opt.none(GasInt)

    let unsignedTx = Transaction(
      txType: TxLegacy,
      nonce: 0,
      gasPrice: 1.GasInt,
      gasLimit: 1_000_000_000.GasInt,
      to: Opt.some initAddress(address.byte),
      value: 0.u256,
      payload: if dataStr.len > 0: dataStr.hexToSeqByte else: @[]
    )
    let tx = signTransaction(unsignedTx, privateKey, ChainId(1), false)
    let fixtureResult = testCallEvm(tx, tx.getSender, vmState)

    if expectedErr:
      check fixtureResult.isError
    else:
      check not fixtureResult.isError
      let c = fixtureResult.output == expected
      if not c: echo "Output  : " & fixtureResult.output.toHex & "\nExpected: " & expected.toHex
      check c

      if gasExpected.isSome:
        if fixtureResult.gasUsed != gasExpected.get:
          debugEcho "GAS: ", fixtureResult.gasUsed, " ", gasExpected.get
        check fixtureResult.gasUsed == gasExpected.get

proc parseFork(x: string): string =
  result = x.capitalizeAscii

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  let
    label = fixtures["func"].getStr
    conf  = getChainConfig(parseFork(fixtures["fork"].getStr))
    data  = fixtures["data"]
    privateKey = PrivateKey.fromHex("7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d")[]
    com = CommonRef.new(newCoreDbRef DefaultDbMemory, config = conf)
    vmState = BaseVMState.new(
      BlockHeader(number: 1'u64, stateRoot: emptyRlpHash),
      BlockHeader(),
      com
    )

  case toLowerAscii(label)
  of "ecrecover": data.doTest(vmState, paEcRecover)
  of "sha256"   : data.doTest(vmState, paSha256)
  of "ripemd"   : data.doTest(vmState, paRipeMd160)
  of "identity" : data.doTest(vmState, paIdentity)
  of "modexp"   : data.doTest(vmState, paModExp)
  of "bn256add" : data.doTest(vmState, paEcAdd)
  of "bn256mul" : data.doTest(vmState, paEcMul)
  of "ecpairing": data.doTest(vmState, paPairing)
  of "blake2f"  : data.doTest(vmState, paBlake2bf)
  of "blsg1add" : data.doTest(vmState, paBlsG1Add)
  of "blsg1mul" : data.doTest(vmState, paBlsG1Mul)
  of "blsg1multiexp" : data.doTest(vmState, paBlsG1MultiExp)
  of "blsg2add" : data.doTest(vmState, paBlsG2Add)
  of "blsg2mul" : data.doTest(vmState, paBlsG2Mul)
  of "blsg2multiexp": data.doTest(vmState, paBlsG2MultiExp)
  of "blspairing": data.doTest(vmState, paBlsPairing)
  of "blsmapg1": data.doTest(vmState, paBlsMapG1)
  of "blsmapg2": data.doTest(vmState, paBlsMapG2)
  else:
    echo "Unknown test vector '" & $label & "'"
    testStatusIMPL = SKIPPED

proc precompilesMain*() =
  suite "Precompiles":
    jsonTest("PrecompileTests", testFixture, skipPrecompilesTests)

when isMainModule:
  precompilesMain()
