# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  unittest2,
  eth/common/headers_rlp,
  web3/eth_api_types,
  web3/engine_api_types,
  web3/primitives,
  web3/conversions,
  web3/execution_types,
  json_rpc/rpcclient,
  json_rpc/rpcserver,
  ../../execution_chain/db/ledger,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/core/tx_pool,
  ../../execution_chain/beacon/beacon_engine,
  ../../execution_chain/common/common,
  ../../hive_integration/engine_client,
  ./eest_helpers

proc sendNewPayload(env: TestEnv, version: uint64, param: PayloadParam): Result[PayloadStatusV1, string] =
  if not env.client.isSome:
    return err("Client is not initialized")

  if version == 3:
    env.client.get().newPayloadV3(
      param.payload,
      param.versionedHashes,
      param.parentBeaconBlockRoot)
  elif version == 4:
    env.client.get().newPayloadV4(
      param.payload,
      param.versionedHashes,
      param.parentBeaconBlockRoot,
      param.excutionRequests)
  else:
    err("Unsupported NewPayload version: " & $version)

proc sendFCU(env: TestEnv, version: uint64, param: PayloadParam): Result[ForkchoiceUpdatedResponse, string] =
  let update = ForkchoiceStateV1(
    headblockHash:      param.payload.blockHash,
    finalizedblockHash: param.payload.blockHash
  )

  if version == 3 and env.client.isSome:
    env.client.get().forkchoiceUpdatedV3(update)
  else:
    err("Unsupported FCU version: " & $version)

proc runTest(env: TestEnv, unit: EngineUnitEnv): Result[void, string] =
  if not env.client.isSome:
    return err("Client is not initialized")

  for enp in unit.engineNewPayloads:
    var status = env.sendNewPayload(enp.newPayloadVersion.uint64, enp.params).valueOr:
      return err(error)

    discard status
    when false:
      # Skip validation error check, use `unit.lastblockhash` to
      # determine if the test is pass.
      if status.validationError.isSome:
        return err(status.validationError.value)

    let y = env.sendFCU(enp.forkchoiceUpdatedVersion.uint64, enp.params).valueOr:
      return err(error)

    discard y
    when false:
      # ditto
      status = y.payloadStatus
      if status.validationError.isSome:
        return err(status.validationError.value)

  let header = env.client.get().latestHeader().valueOr:
    return err(error)

  if unit.lastblockhash != header.computeRlpHash:
    return err("last block hash mismatch")

  ok()

proc processFile*(fileName: string): bool =
  let
    fixture = parseFixture(fileName, EngineFixture)

  var testPass = true
  for unit in fixture.units:
    let header = unit.unit.genesisBlockHeader.to(Header)
    doAssert(unit.unit.genesisBlockHeader.hash == header.computeRlpHash)
    let env = prepareEnv(unit.unit, header, true)
    env.runTest(unit.unit).isOkOr:
      echo "\nTestName: ", unit.name, " RunTest error: ", error, "\n"
      testPass = false
    env.close()

  return testPass

when isMainModule:
  import std/[cmdline, os]

  if paramCount() == 0:
    let testFile = getAppFilename().splitPath().tail
    echo "Usage: " & testFile & " vector.json"
    quit(QuitFailure)

  check processFile(paramStr(1))
