# nim-graphql
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, json, unittest],
  stew/byteutils,
  eth/[p2p, common, trie/db, rlp, trie],
  eth/p2p/rlpx_protocols/eth_protocol,
  graphql, ../nimbus/graphql/ethapi, graphql/test_common,
  ../nimbus/[genesis, config, chain_config], ../nimbus/db/[db_chain, state_db],
  ../nimbus/p2p/chain, ../premix/parser, ./test_helpers

type
  EthBlock = object
    header: BlockHeader
    transactions: seq[Transaction]
    uncles: seq[BlockHeader]

const
  caseFolder = "tests" / "graphql"
  dataFolder  = "tests" / "fixtures" / "eth_tests" / "BlockchainTests" / "ValidBlocks" / "bcUncleTest"

proc toBlock(n: JsonNode, key: string): EthBlock =
  let rlpBlob = hexToSeqByte(n[key].str)
  rlp.decode(rlpBlob, EthBlock)

proc setupChain(chainDB: BaseChainDB) =
  var jn = json.parseFile(dataFolder / "oneUncle.json")
  for k, v in jn:
    if v["network"].str == "Istanbul":
      jn = v
      break

  let genesis = jn.toBlock("genesisRLP")

  let conf = getConfiguration()
  conf.customGenesis.genesis.nonce      = genesis.header.nonce
  conf.customGenesis.genesis.extraData  = genesis.header.extraData
  conf.customGenesis.genesis.gasLimit   = genesis.header.gasLimit
  conf.customGenesis.genesis.difficulty = genesis.header.difficulty
  conf.customGenesis.genesis.mixHash    = genesis.header.mixDigest
  conf.customGenesis.genesis.coinBase   = genesis.header.coinbase
  conf.customGenesis.genesis.timestamp  = genesis.header.timestamp
  if not parseGenesisAlloc($(jn["pre"]), conf.customGenesis.genesis.alloc):
    quit(QuitFailure)

  chainDB.initializeEmptyDb()

  let blocks = jn["blocks"]
  var headers: seq[BlockHeader]
  var bodies: seq[BlockBody]
  for n in blocks:
    let ethBlock = n.toBlock("rlp")
    headers.add ethBlock.header
    bodies.add BlockBody(
      transactions: ethBlock.transactions,
      uncles: ethBlock.uncles
    )

  let chain = newChain(chainDB)
  let res = chain.persistBlocks(headers, bodies)
  assert(res == ValidationResult.OK)

proc graphqlMain*() =
  let conf = getConfiguration()
  conf.net.networkId = CustomNet
  conf.customGenesis.config = ChainConfig(
    chainId             : MainNet.ChainId,
    byzantiumBlock      : 0.toBlockNumber,
    constantinopleBlock : 0.toBlockNumber,
    petersburgBlock     : 0.toBlockNumber,
    istanbulBlock       : 10.toBlockNumber,
    muirGlacierBlock    : high(BlockNumber).toBlockNumber,
    berlinBlock         : high(BlockNumber).toBlockNumber
  )

  let
    ethNode = setupEthNode(eth)
    chainDB = newBaseChainDB(newMemoryDb(),
      pruneTrie = false,
      conf.net.networkId
    )

  chainDB.setupChain()
  let ctx = setupGraphqlContext(chainDB, ethNode)
  when isMainModule:
    ctx.main(caseFolder, purgeSchema = false)
  else:
    disableParamFiltering()
    ctx.executeCases(caseFolder, purgeSchema = false)

when isMainModule:
  processArguments()
  graphqlMain()
