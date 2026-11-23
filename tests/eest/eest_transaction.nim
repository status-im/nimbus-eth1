# Nimbus
# Copyright (c) 2019-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.define: unittest2DisableParamFiltering.}
{.push raises: [].}

import
  std/[os],
  unittest2,
  results,
  eth/common/transactions_rlp,
  ../../execution_api/conversions,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/transaction/call_types,
  ../../execution_chain/core/validate,
  ../../execution_chain/common/common,
  ../../execution_chain/transaction,
  ./eest_parser

import ../../tools/common/helpers as chp except HardFork

const
  nameToFork = {
    "Frontier"         : HardFork.Frontier,
    "Homestead"        : HardFork.Homestead,
    "TangerineWhistle" : HardFork.Tangerine,
    "SpuriousDragon"   : HardFork.Spurious,
    "Byzantium"        : HardFork.Byzantium,
    "Constantinople"   : HardFork.Constantinople,
    "ConstantinopleFix": HardFork.Petersburg,
    "Istanbul"         : HardFork.Istanbul,
    "Berlin"           : HardFork.Berlin,
    "London"           : HardFork.London,
    "Paris"            : HardFork.MergeFork,
    "Shanghai"         : HardFork.Shanghai,
    "Cancun"           : HardFork.Cancun,
    "Prague"           : HardFork.Prague,
    "Osaka"            : HardFork.Osaka,
    "Amsterdam"        : HardFork.Amsterdam,
    "Bogota"           : HardFork.Bogota,
  }.toTable

proc runTest(unit: TransactionUnitEnv): Result[void, string] =
  var tx: Transaction
  try:
    tx = rlp.decode(unit.txbytes, Transaction)
  except RlpError as exc:
    # Only transactions that are invalid for every fork may fail to decode
    if unit.result.exception.len > 0:
      return ok()
    else:
      return err("Transaction decoding not expected to fail: " & exc.msg)

  let
    config = getChainConfig(unit.result.network).expect("ok")
    memDB  = newCoreDbRef DefaultDbMemory
    com    = CommonRef.new(memDB, config)
    fork   = nameToFork.getOrDefault(unit.result.network, Frontier)

  if unit.result.hash.isSome:
    let
      get  = tx.computeRlpHash
      want = unit.result.hash.value
    if get != want:
      return err("Transaction hash mismatch, want: " & $want & ", get: " & $get)

  if unit.result.sender.isSome:
    let
      sender = tx.recoverSenderCached().valueOr:
        return err("Cannot recover sender")
      want = unit.result.sender.value
    if sender != want:
      return err("Transaction sender mismatch, want: " & $want & ", get: " & $sender)

    if unit.result.intrinsicGas.isSome:
      let
        intrinsic = tx.intrinsicGas(fork, sender)
        want = GasInt unit.result.intrinsicGas.value
      if intrinsic.execution != want:
        return err("Transaction intrinsic gas mismatch, want: " & $want & ", get: " & $intrinsic.execution)
      ? com.validateTxBasic(tx, intrinsic, fork)

  ok()

proc processFile*(
    filePath: string,
    statelessEnabled = false,
    parallelEnabled = false,
    skipFiles: seq[string] = @[],
) =
  let fixture = parseFixture(filePath, TransactionFixture)
  let fileName = filePath.splitPath().tail

  for unit in fixture.units:
    let
      testName = unit.name
      testUnit = unit.unit
    test testName & " from " & filePath:
      if fileName in skipFiles:
        skip()
      else:
        let testResult = runTest(testUnit)
        check testResult == Result[void, string].ok()

when isMainModule:
  import std/cmdline

  if paramCount() == 0:
    let testFile = getAppFilename().splitPath().tail
    echo "Usage: " & testFile & " vector.json"
    quit(QuitFailure)

  processFile(paramStr(1))
