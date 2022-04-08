# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, json],
  eth/[p2p, trie/db], ../../../nimbus/db/db_chain,
  ../../../nimbus/sync/protocol_ethxx,
  ../../../nimbus/[genesis, config, conf_utils, context],
  ../../../nimbus/graphql/ethapi, ../../../tests/test_helpers,
  ../../../nimbus/utils/tx_pool,
  graphql, ../sim_utils

const
  baseFolder  = "hive_integration" / "nodocker" / "graphql"
  blocksFile  = baseFolder / "init" / "blocks.rlp"
  genesisFile = baseFolder / "init" / "genesis.json"
  caseFolder  = baseFolder / "testcases"

proc processNode(ctx: GraphqlRef, node: JsonNode, fileName: string, testStatusIMPL: var TestStatus) =
  let request = node["request"]
  let responses = node["responses"]
  let statusCode = node["statusCode"].getInt()

  let savePoint = ctx.getNameCounter()
  let res = ctx.parseQuery(request.getStr())

  block:
    if res.isErr:
      if statusCode == 200:
        debugEcho res.error
      check statusCode != 200
      break

    let resp = JsonRespStream.new()
    let r = ctx.executeRequest(respStream(resp))
    if r.isErr:
      if statusCode == 200:
        debugEcho r.error
      check statusCode != 200
      break

    check statusCode == 200
    check r.isOk

    let nimbus = resp.getString()
    var resultOK = false
    for x in responses:
      let hive = $(x["data"])
      if nimbus == hive:
        resultOK = true
        break

    check resultOK
    if not resultOK:
      debugEcho "NIMBUS RESULT: ", nimbus
      for x in responses:
        let hive = $(x["data"])
        debugEcho "HIVE RESULT: ", hive

  ctx.purgeQueries()
  ctx.purgeNames(savePoint)

proc main() =
  let
    conf = makeConfig(@["--custom-network:" & genesisFile])
    ethCtx = newEthContext()
    ethNode = setupEthNode(conf, ethCtx, eth)
    chainDB = newBaseChainDB(newMemoryDB(),
      pruneTrie = false,
      conf.networkId,
      conf.networkParams
    )

  initializeEmptyDb(chainDB)

  let txPool = TxPoolRef.new(chainDB, conf.engineSigner)
  discard importRlpBlock(blocksFile, chainDB)
  let ctx = setupGraphqlContext(chainDB, ethNode, txPool)

  runTest("GraphQL", caseFolder):
    let node = parseFile(fileName)
    ctx.processNode(node, fileName, testStatusIMPL)

main()
