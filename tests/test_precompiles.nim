# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, ../nimbus/vm/precompiles, json, stew/byteutils, test_helpers, os, tables,
  strformat, strutils, eth/trie/db, eth/common, ../nimbus/db/db_chain,
  ../nimbus/[vm_types, vm_state], ../nimbus/vm/computation, macros,
  ../nimbus/vm/interpreter/vm_forks

proc initAddress(i: byte): EthAddress = result[19] = i

template doTest(fixture: JsonNode, fork: Fork, address: PrecompileAddresses): untyped =
  for test in fixture:
    let
      blockNum = 1.u256 # TODO: Check other forks
      header = BlockHeader(blockNumber: blockNum)
      expectedErr = test.hasKey("ExpectedError")
      expected = if test.hasKey("Expected"): hexToSeqByte(test["Expected"].getStr) else: @[]
      dataStr = test["Input"].getStr
      data = if dataStr.len > 0: dataStr.hexToSeqByte else: @[]
      vmState = newBaseVMState(header.stateRoot, header, newBaseChainDB(newMemoryDb()))
      gas = 1_000_000_000.GasInt
      gasPrice = 1.GasInt
      sender = initAddress(0x00)
      toAddress = initAddress(address.byte)
      gasCost = if test.hasKey("Gas"): test["Gas"].getInt else: -1

    vmState.setupTxContext(
      origin = sender,
      gasPrice = gasPrice
    )

    var
      message = Message(
        kind: evmcCall,
        gas: gas,
        sender: sender,
        contractAddress: toAddress,
        codeAddress: toAddress,
        value: 0.u256,
        data: data
        )
      comp = newComputation(vmState, message)

    let initialGas = comp.gasMeter.gasRemaining
    discard execPrecompiles(comp, fork)

    if expectedErr:
      check comp.isError
    else:
      let c = comp.output == expected
      if not c: echo "Output  : " & comp.output.toHex & "\nExpected: " & expected.toHex
      check c

      if gasCost >= 0:
        let gasFee = initialGas - comp.gasMeter.gasRemaining
        if gasFee != gasCost:
          debugEcho "GAS: ", gasFee, " ", gasCost
        check gasFee == gasCost

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  let
    label = fixtures["func"].getStr
    fork  = parseEnum[Fork](fixtures["fork"].getStr)
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
  of "blsg1add" : data.doTest(fork, paBlsG1Add)
  of "blsg1mul" : data.doTest(fork, paBlsG1Mul)
  of "blsg1multiexp" : data.doTest(fork, paBlsG1MultiExp)
  of "blsg2add" : data.doTest(fork, paBlsG2Add)
  of "blsg2mul" : data.doTest(fork, paBlsG2Mul)
  of "blsg2multiexp": data.doTest(fork, paBlsG2MultiExp)
  of "blspairing": data.doTest(fork, paBlsPairing)
  of "blsmapg1": data.doTest(fork, paBlsMapG1)
  of "blsmapg2": data.doTest(fork, paBlsMapG2)
  else:
    echo "Unknown test vector '" & $label & "'"
    testStatusIMPL = SKIPPED

proc precompilesMain*() =
  suite "Precompiles":
    jsonTest("PrecompileTests", testFixture)

when isMainModule:
  precompilesMain()
