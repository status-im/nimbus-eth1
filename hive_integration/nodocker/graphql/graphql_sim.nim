# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, parseopt, json],
  eth/[p2p, trie/db], ../../../nimbus/db/db_chain,
  eth/p2p/rlpx_protocols/eth_protocol,
  ../../../nimbus/[genesis, config, conf_utils],
  ../../../nimbus/graphql/ethapi, ../../../tests/test_helpers,
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
  var msg: string
  var opt = initOptParser("--customnetwork:" & genesisFile)
  let res = processArguments(msg, opt)
  if res != Success:
    echo msg
    quit(QuitFailure)

  let
    conf = getConfiguration()
    ethNode = setupEthNode(eth)
    chainDB = newBaseChainDB(newMemoryDb(),
      pruneTrie = false,
      id = toPublicNetwork(conf.net.networkId)
    )

  initializeEmptyDb(chainDB)
  importRlpBlock(blocksFile, chainDB)
  let ctx = setupGraphqlContext(chainDB, ethNode)

  runTest("GraphQL", caseFolder):
    let node = parseFile(fileName)
    ctx.processNode(node, fileName, testStatusIMPL)

main()
