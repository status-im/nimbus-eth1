# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, json, strutils, times, typetraits, options],
  stew/[byteutils, results],
  eth/common,
  ../sim_utils,
  ../../../tools/common/helpers as chp,
  ../../../tools/evmstate/helpers as ehp,
  ../../../tests/test_helpers,
  ../../../nimbus/beacon/web3_eth_conv,
  ../../../nimbus/beacon/execution_types,
  ../../../nimbus/beacon/payload_conv,
  ../engine/engine_client,
  ./test_env

const
  baseFolder = "hive_integration/nodocker/pyspec"
  caseFolder = baseFolder & "/testcases"
  supportedNetwork = ["Merge", "Shanghai", "MergeToShanghaiAtTime15k"]

proc getPayload(node: JsonNode): ExecutionPayloadV1OrV2 =
  let rlpBytes = hexToSeqByte(node.getStr)
  executionPayloadV1V2(rlp.decode(rlpBytes, EthBlock))

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

        if val != sRes.value:
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

proc runTest(node: JsonNode, network: string): TestStatus =
  let conf = getChainConfig(network)
  var t = TestEnv(conf: makeTestConfig())
  t.setupELClient(conf, node)

  let blks = node["blocks"]
  var latestValidHash = common.Hash256()
  result = TestStatus.OK
  for blkNode in blks:
    let expectedStatus = if "expectException" in blkNode:
                           PayloadExecutionStatus.invalid
                         else:
                           PayloadExecutionStatus.valid
    let payload = getPayload(blkNode["rlp"])
    let res = t.rpcClient.newPayloadV2(payload)
    if res.isErr:
      result = TestStatus.Failed
      echo "unable to send block ", payload.blockNumber.uint64, ": ", res.error
      break

    let pStatus = res.value
    if pStatus.status == PayloadExecutionStatus.valid:
      latestValidHash = ethHash pStatus.latestValidHash.get

    if pStatus.status != expectedStatus:
      result = TestStatus.Failed
      echo "payload status mismatch for block ", payload.blockNumber.uint64, ", status: ", pStatus.status
      if pStatus.validationError.isSome:
        echo pStatus.validationError.get
      break

  block:
    # only update head of beacon chain if valid response occurred
    if latestValidHash != common.Hash256():
      # update with latest valid response
      let fcState = ForkchoiceStateV1(headBlockHash: BlockHash latestValidHash.data)
      let res = t.rpcClient.forkchoiceUpdatedV2(fcState)
      if res.isErr:
        result = TestStatus.Failed
        echo "unable to update head of beacon chain: ", res.error
        break

    if not validatePostState(node, t):
      result = TestStatus.Failed
      break

  t.stopELClient()

proc main() =
  var stat: SimStat
  let start = getTime()

  for fileName in walkDirRec(caseFolder):
    if not fileName.endsWith(".json"):
      continue

    let fixtureTests = json.parseFile(fileName)
    for name, fixture in fixtureTests:
      let network = fixture["network"].getStr
      if network notin supportedNetwork:
        # skip pre Merge tests
        continue

      let status = runTest(fixture, network)
      stat.inc(name, status)

  let elpd = getTime() - start
  print(stat, elpd, "pyspec")

main()
