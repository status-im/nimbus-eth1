# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, json, strutils, times, typetraits],
  stew/byteutils,
  eth/common/eth_types_rlp,
  json_rpc/rpcclient,
  web3/execution_types,
  taskpools,
  ../sim_utils,
  ../../../tools/common/helpers as chp,
  ../../../tools/evmstate/helpers as ehp,
  ../../../execution_chain/beacon/web3_eth_conv,
  ../../../execution_chain/beacon/payload_conv,
  ../engine/engine_client,
  ../engine/types,
  ./test_env

const
  baseFolder = "hive_integration/nodocker/pyspec"
  supportedNetwork = [
    "Merge",
    "Shanghai",
    "MergeToShanghaiAtTime15k",
    "Cancun",
    "ShanghaiToCancunAtTime15k",
  ]

type
  Payload = object
    badBlock: bool
    payload: ExecutableData

proc getPayload(node: JsonNode): Payload  =
  try:
    let
      rlpBytes = hexToSeqByte(node.getStr)
      blk = rlp.decode(rlpBytes, EthBlock)
    Payload(
      badBlock: false,
      payload: ExecutableData(
        basePayload: executionPayload(blk),
        beaconRoot: blk.header.parentBeaconBlockRoot,
      )
    )
  except RlpError:
    Payload(
      badBlock: true,
    )

proc validatePostState(node: JsonNode, t: TestEnv): bool =
  # check nonce, balance & storage of accounts in final block against fixture values
  for account, genesisAccount in postState(node["postState"]):
    # get nonce & balance from last block (end of test execution)
    let nonceRes = t.rpcClient.nonceAt(account)
    if nonceRes.isErr:
      echo "unable to call nonce from account: " & account.toHex
      echo nonceRes.error
      return false

    let balanceRes = t.rpcClient.balanceAt(account)
    if balanceRes.isErr:
      echo "unable to call balance from account: " & account.toHex
      echo balanceRes.error
      return false

    # check final nonce & balance matches expected in fixture
    if genesisAccount.nonce != nonceRes.value:
      echo "nonce recieved from account 0x",
        account.toHex,
        " doesn't match expected ",
        genesisAccount.nonce,
        " got ",
        nonceRes.value
      return false

    if genesisAccount.balance != balanceRes.value:
      echo "balance recieved from account 0x",
        account.toHex,
        " doesn't match expected ",
        genesisAccount.balance,
        " got ",
        balanceRes.value
      return false

    # check final storage
    if genesisAccount.storage.len > 0:
      for slot, val in genesisAccount.storage:
        let sRes = t.rpcClient.storageAt(account, slot)
        if sRes.isErr:
          echo "unable to call storage from account: 0x",
            account.toHex,
            " at slot 0x",
            slot.toHex
          echo sRes.error
          return false

        if val.to(Bytes32) != sRes.value:
          echo "storage recieved from account 0x",
            account.toHex,
            " at slot 0x",
            slot.toHex,
            " doesn't match expected 0x",
            val.toHex,
            " got 0x",
            sRes.value.toHex
          return false

  return true

proc runTest(node: JsonNode, taskPool: Taskpool, network: string): TestStatus =
  let conf = getChainConfig(network)
  var env = setupELClient(conf, taskPool, node)

  let blks = node["blocks"]
  var
    latestValidHash = default(Hash32)
    latestVersion: Version

  result = TestStatus.OK
  for blkNode in blks:
    let expectedStatus = if "expectException" in blkNode:
                           PayloadExecutionStatus.invalid
                         else:
                           PayloadExecutionStatus.valid
    let
      badBlock = blkNode.hasKey("expectException")
      payload = getPayload(blkNode["rlp"])

    if badBlock == payload.badBlock and badBlock == true:
      # It could be the rlp decoding succeed, but the actual
      # block validation is failed in engine api
      # So, we skip newPayload call only if decoding is also
      # failed
      break

    latestVersion = payload.payload.version

    let res = env.rpcClient.newPayload(latestVersion, payload.payload)
    if res.isErr:
      result = TestStatus.Failed
      echo "unable to send block ",
        payload.payload.blockNumber.uint64, ": ", res.error
      break

    let pStatus = res.value
    if pStatus.status == PayloadExecutionStatus.valid:
      latestValidHash = pStatus.latestValidHash.get

    if pStatus.status != expectedStatus:
      result = TestStatus.Failed
      echo "payload status mismatch for block ",
        payload.payload.blockNumber.uint64,
        ", status: ", pStatus.status,
        ",expected: ", expectedStatus
      if pStatus.validationError.isSome:
        echo pStatus.validationError.get
      break

  block blockOne:
    # only update head of beacon chain if valid response occurred
    if latestValidHash != default(Hash32):
      # update with latest valid response
      let fcState = ForkchoiceStateV1(headBlockHash: Hash32 latestValidHash.data)
      let res = env.rpcClient.forkchoiceUpdated(latestVersion, fcState)
      if res.isErr:
        result = TestStatus.Failed
        echo "unable to update head of beacon chain: ", res.error
        break blockOne

    if not validatePostState(node, env):
      result = TestStatus.Failed
      break blockOne

  env.stopELClient()

const
  skipName = [
    "nothing skipped",
  ]

  caseFolderCancun   = "tests/fixtures/eth_tests/BlockchainTests/Pyspecs"
  caseFolderShanghai = baseFolder & "/testcases"

proc collectTestVectors(): seq[string] =
  for fileName in walkDirRec(caseFolderCancun):
    result.add fileName

  for fileName in walkDirRec(caseFolderShanghai):
    result.add fileName

proc main() =
  var stat: SimStat
  let taskPool = Taskpool.new()
  let start = getTime()

  let testVectors = collectTestVectors()
  for fileName in testVectors:
    if not fileName.endsWith(".json"):
      continue

    let suspect = splitPath(fileName)
    if suspect.tail in skipName:
      let fixtureTests = json.parseFile(fileName)
      for name, fixture in fixtureTests:
        stat.inc(name, TestStatus.Skipped)
      continue

    let fixtureTests = json.parseFile(fileName)
    for name, fixture in fixtureTests:
      let network = fixture["network"].getStr
      if network notin supportedNetwork:
        # skip pre Merge tests
        continue

      try:
        let status = runTest(fixture, taskPool, network)
        stat.inc(name, status)
      except CatchableError as ex:
        debugEcho ex.msg
        stat.inc(name, TestStatus.Failed)

  let elpd = getTime() - start
  print(stat, elpd, "pyspec")

main()
