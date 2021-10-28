# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[strformat, strutils, json, os, tables, macros, options],
  unittest2, stew/byteutils,
  eth/[trie/db, common, keys],

  ../nimbus/[vm_computation,
    vm_state,
    forks,
    constants,
    vm_precompiles,
    transaction,
    db/db_chain,
    transaction/call_evm
    ],

  ./test_helpers, ./test_allowed_to_fail

proc initAddress(i: byte): EthAddress = result[19] = i

template doTest(fixture: JsonNode, fork: Fork, address: PrecompileAddresses): untyped =
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

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  let
    label = fixtures["func"].getStr
    fork  = parseEnum[Fork](fixtures["fork"].getStr.toLowerAscii)
    data  = fixtures["data"]
    privateKey = PrivateKey.fromHex("7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d")[]
    header = BlockHeader(blockNumber: 1.u256)
    chainDB = newBaseChainDB(newMemoryDb())

  chainDB.initStateDB(header.stateRoot)
  let vmState = newBaseVMState(chainDB.stateDB, header, chainDB)

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
