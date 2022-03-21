# nim-graphql
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, json],
  stew/byteutils, unittest2,
  eth/[p2p, common, trie/db, rlp],
  graphql, ../nimbus/graphql/ethapi, graphql/test_common,
  ../nimbus/sync/protocol_ethxx,
  ../nimbus/[genesis, config, chain_config, context],
  ../nimbus/db/[db_chain],
  ../nimbus/p2p/chain, ./test_helpers,
  ../nimbus/utils/tx_pool

type
  EthBlock = object
    header: BlockHeader
    transactions: seq[Transaction]
    uncles: seq[BlockHeader]

const
  caseFolder = "tests" / "graphql" / "eth" & $ethVersion
  dataFolder  = "tests" / "fixtures" / "eth_tests" / "BlockchainTests" / "ValidBlocks" / "bcUncleTest"

proc toBlock(n: JsonNode, key: string): EthBlock =
  let rlpBlob = hexToSeqByte(n[key].str)
  rlp.decode(rlpBlob, EthBlock)

proc setupChain(): BaseChainDB =
  let config = ChainConfig(
    chainId             : MainNet.ChainId,
    byzantiumBlock      : 0.toBlockNumber,
    constantinopleBlock : 0.toBlockNumber,
    petersburgBlock     : 0.toBlockNumber,
    istanbulBlock       : 0.toBlockNumber,
    muirGlacierBlock    : 0.toBlockNumber,
    berlinBlock         : 10.toBlockNumber,
    londonBlock         : high(BlockNumber),
    arrowGlacierBlock   : high(BlockNumber)
  )

  var jn = json.parseFile(dataFolder / "oneUncle.json")
  for k, v in jn:
    if v["network"].str == "Istanbul":
      jn = v
      break

  let gen = jn.toBlock("genesisRLP")
  var genesis = Genesis(
    nonce     : gen.header.nonce,
    extraData : gen.header.extraData,
    gasLimit  : gen.header.gasLimit,
    difficulty: gen.header.difficulty,
    mixHash   : gen.header.mixDigest,
    coinBase  : gen.header.coinbase,
    timestamp : gen.header.timestamp,
    baseFeePerGas: gen.header.fee
  )
  if not parseGenesisAlloc($(jn["pre"]), genesis.alloc):
    quit(QuitFailure)

  let customNetwork = NetworkParams(
    config: config,
    genesis: genesis
  )

  let chainDB = newBaseChainDB(
    newMemoryDb(),
    pruneTrie = false,
    CustomNet,
    customNetwork
  )
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

  chainDB

proc graphqlMain*() =
  let
    conf    = makeTestConfig()
    ethCtx  = newEthContext()
    ethNode = setupEthNode(conf, ethCtx, eth)
    chainDB = setupChain()
    txPool  = TxPoolRef.new(chainDB, conf.engineSigner)

  let ctx = setupGraphqlContext(chainDB, ethNode, txPool)
  when isMainModule:
    ctx.main(caseFolder, purgeSchema = false)
  else:
    disableParamFiltering()
    ctx.executeCases(caseFolder, purgeSchema = false)

when isMainModule:
  graphqlMain()
