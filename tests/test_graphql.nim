# nim-graphql
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json],
  stew/byteutils,
  eth/[p2p, rlp],
  graphql, ../nimbus/graphql/ethapi, graphql/test_common,
  ../nimbus/sync/protocol,
  ../nimbus/config,
  ../nimbus/core/[chain, tx_pool],
  ../nimbus/common/[common, context],
  ./test_helpers

type
  EthBlock = object
    header: BlockHeader
    transactions: seq[Transaction]
    uncles: seq[BlockHeader]

const
  caseFolder = "tests/graphql"
  dataFolder  = "tests/fixtures/eth_tests/BlockchainTests/ValidBlocks/bcUncleTest"

proc toBlock(n: JsonNode, key: string): EthBlock =
  let rlpBlob = hexToSeqByte(n[key].str)
  rlp.decode(rlpBlob, EthBlock)

proc setupChain(): CommonRef =
  let config = ChainConfig(
    chainId             : MainNet.ChainId,
    byzantiumBlock      : some(0.toBlockNumber),
    constantinopleBlock : some(0.toBlockNumber),
    petersburgBlock     : some(0.toBlockNumber),
    istanbulBlock       : some(0.toBlockNumber),
    muirGlacierBlock    : some(0.toBlockNumber),
    berlinBlock         : some(10.toBlockNumber)
  )

  var jn = json.parseFile(dataFolder & "/oneUncle.json")
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

  let com = CommonRef.new(
    newCoreDbRef LegacyDbMemory,
    pruneTrie = false,
    CustomNet,
    customNetwork
  )
  com.initializeEmptyDb()

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

  let chain = newChain(com)
  let res = chain.persistBlocks(headers, bodies)
  assert(res == ValidationResult.OK)

  com

proc graphqlMain*() =
  let
    conf    = makeTestConfig()
    ethCtx  = newEthContext()
    ethNode = setupEthNode(conf, ethCtx, eth)
    com     = setupChain()
    txPool  = TxPoolRef.new(com, conf.engineSigner)

  let ctx = setupGraphqlContext(com, ethNode, txPool)
  when isMainModule:
    ctx.main(caseFolder, purgeSchema = false)
  else:
    ctx.executeCases(caseFolder, purgeSchema = false)

when isMainModule:
  graphqlMain()
