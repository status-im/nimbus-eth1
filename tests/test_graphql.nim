# nim-graphql
# Copyright (c) 2021-2024 Status Research & Development GmbH
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

const
  caseFolder = "tests/graphql"
  dataFolder  = "tests/fixtures/eth_tests/BlockchainTests/ValidBlocks/bcUncleTest"

proc toBlock(n: JsonNode, key: string): Block =
  let rlpBlob = hexToSeqByte(n[key].str)
  rlp.decode(rlpBlob, Block)

proc setupChain(): ForkedChainRef =
  let config = ChainConfig(
    chainId             : MainNet.ChainId,
    byzantiumBlock      : Opt.some(0.BlockNumber),
    constantinopleBlock : Opt.some(0.BlockNumber),
    petersburgBlock     : Opt.some(0.BlockNumber),
    istanbulBlock       : Opt.some(0.BlockNumber),
    muirGlacierBlock    : Opt.some(0.BlockNumber),
    berlinBlock         : Opt.some(10.BlockNumber)
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
    mixHash   : gen.header.mixHash,
    coinBase  : gen.header.coinbase,
    timestamp : gen.header.timestamp,
    baseFeePerGas: gen.header.baseFeePerGas
  )
  if not parseGenesisAlloc($(jn["pre"]), genesis.alloc):
    quit(QuitFailure)

  let
    customNetwork = NetworkParams(
      config: config,
      genesis: genesis
    )
    com = CommonRef.new(
      newCoreDbRef DefaultDbMemory,
      taskpool = nil,
      CustomNet,
      customNetwork
    )
    chain = ForkedChainRef.init(com)
    blocks = jn["blocks"]

  for n in blocks:
    let blk = n.toBlock("rlp")
    chain.importBlock(blk).isOkOr:
      doAssert(false, error)

  chain

proc graphqlMain*() =
  let
    conf    = makeTestConfig()
    ethCtx  = newEthContext()
    ethNode = setupEthNode(conf, ethCtx, eth)
    chain   = setupChain()
    txPool  = TxPoolRef.new(chain)

  let ctx = setupGraphqlContext(chain, ethNode, txPool)
  when isMainModule:
    ctx.main(caseFolder, purgeSchema = false)
  else:
    ctx.executeCases(caseFolder, purgeSchema = false)

when isMainModule:
  graphqlMain()
