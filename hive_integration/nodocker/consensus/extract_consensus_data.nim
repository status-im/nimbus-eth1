# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json],
  stew/byteutils,
  ../../../tools/common/helpers,
  ../../../nimbus/common/chain_config

type
  Blob = seq[byte]

  ChainData* = object
    params*: NetworkParams
    lastBlockHash*: string
    blocksRlp*: seq[Blob]

const genFields = [
  "nonce",
  "timestamp",
  "extraData",
  "gasLimit",
  "difficulty",
  "mixHash",
  "coinbase"
]

proc parseChainConfig(n: JsonNode): ChainConfig =
  getChainConfig(n["network"].getStr)

proc optionalField(n: string, genesis, gen: JsonNode) =
  if n in gen:
    genesis[n] = gen[n]

proc parseGenesis(n: JsonNode): Genesis =
  let gen = n["genesisBlockHeader"]
  var genesis = newJObject()
  for x in genFields:
    genesis[x] = gen[x]
  optionalField("baseFeePerGas", genesis, gen)
  optionalField("dataGasUsed", genesis, gen)
  optionalField("excessDataGas", genesis, gen)
  genesis["alloc"] = n["pre"]
  parseGenesis($genesis)

proc extractChainData*(n: JsonNode): ChainData =
  result.params = NetworkParams(
    genesis: parseGenesis(n),
    config : parseChainConfig(n))
  result.lastblockhash = n["lastblockhash"].getStr

  let blks = n["blocks"]
  for x in blks:
    let hex = x["rlp"].getStr
    let bytes = hexToSeqByte(hex)
    result.blocksRlp.add bytes
