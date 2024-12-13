# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, json, times],
  eth/p2p,
  ../../../nimbus/sync/protocol,
  ../../../nimbus/config,
  ../../../nimbus/graphql/ethapi,
  ../../../tests/test_helpers,
  ../../../nimbus/core/[tx_pool, block_import],
  ../../../nimbus/common,
  graphql, ../sim_utils

const
  baseFolder  = "hive_integration" / "nodocker" / "graphql"
  blocksFile  = baseFolder / "init" / "blocks.rlp"
  genesisFile = baseFolder / "init" / "genesis.json"
  caseFolder  = baseFolder / "testcases"

template testCond(expr: untyped) =
  if not (expr):
    result = TestStatus.Failed

proc processNode(ctx: GraphqlRef, node: JsonNode, fileName: string): TestStatus =
  let request = node["request"]
  let responses = node["responses"]
  let statusCode = node["statusCode"].getInt()

  let savePoint = ctx.getNameCounter()
  let res = ctx.parseQuery(request.getStr())

  result = TestStatus.OK
  block:
    if res.isErr:
      if statusCode == 200:
        debugEcho res.error
      testCond statusCode != 200
      break

    let resp = JsonRespStream.new()
    let r = ctx.executeRequest(respStream(resp))
    if r.isErr:
      if statusCode == 200:
        debugEcho r.error
      testCond statusCode != 200
      break

    testCond statusCode == 200
    testCond r.isOk

    let nimbus = resp.getString()
    var resultOK = false
    for x in responses:
      let hive = $(x["data"])
      if nimbus == hive:
        resultOK = true
        break

    testCond resultOK
    if not resultOK:
      debugEcho "NIMBUS RESULT: ", nimbus
      for x in responses:
        let hive = $(x["data"])
        debugEcho "HIVE RESULT: ", hive

  ctx.purgeQueries()
  ctx.purgeNames(savePoint)

proc main() =
  let
    conf    = makeConfig(@["--custom-network:" & genesisFile])
    ethCtx  = newEthContext()
    ethNode = setupEthNode(conf, ethCtx, eth)
    com     = CommonRef.new(newCoreDbRef DefaultDbMemory,
      conf.networkId,
      conf.networkParams
    )
    chain   = ForkedChainRef.init(com)
    txPool  = TxPoolRef.new(chain)
    
  discard importRlpBlock(blocksFile, com)
  let ctx = setupGraphqlContext(com, ethNode, txPool)

  var stat: SimStat
  let start = getTime()

  # txPool must be informed of active head
  # so it can know the latest account state
  # e.g. "sendRawTransaction Nonce too low" case
  doAssert txPool.smartHead(chain.latestHeader)

  for fileName in walkDirRec(
                 caseFolder, yieldFilter = {pcFile,pcLinkToFile}):
    if not fileName.endsWith(".json"):
      continue

    let (_, name) = fileName.splitPath()
    let node = parseFile(fileName)
    let status = ctx.processNode(node, fileName)
    stat.inc(name, status)

    # simulate the real simulator
    txPool.disposeAll()

  let elpd = getTime() - start
  print(stat, elpd, "graphql")

main()
