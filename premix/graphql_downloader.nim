# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/json,
  chronos, results, eth/common,
  graphql/httpclient,
  ./parser

const ethQuery = """
fragment headerFields on Block {
  parentHash: parent { value: hash }
  sha3Uncles: ommerHash
  miner { value: address }
  stateRoot
  transactionsRoot
  receiptsRoot
  logsBloom
  difficulty
  number
  gasLimit
  gasUsed
  timestamp
  extraData
  mixHash
  nonce
  baseFeePerGas # EIP-1559
}

query getBlock($blockNumber: Long!) {
  chainID # EIP-1559
  block(number: $blockNumber) {
    ... headerFields
    ommerCount
    ommers {
      ... headerFields
    }
    transactionCount
    transactions {
      nonce
      gasPrice
      gas
      to {value: address}
      value
      input: inputData
      v
      r
      s
      maxFeePerGas # EIP-1559
      maxPriorityFeePerGas # EIP-1559
      effectiveGasPrice # EIP-1559
      type
      hash
      from {value: address}
      accessList {
        address
        storageKeys
      }
      index
    }
  }
}
"""

type
  Block* = object
    header*: BlockHeader
    body*: BlockBody

proc fromJson(_: type ChainId, n: JsonNode, name: string): ChainId =
  var chainId: int
  fromJson(n, name, chainId)
  ChainId(chainId)

proc requestBlock*(blockNumber: BlockNumber, parseTx = true): Block =
  let address = initTAddress("127.0.0.1:8545")
  let clientRes = GraphqlHttpClientRef.new(address)
  if clientRes.isErr:
    raise newException(ValueError, clientRes.error)

  let client = clientRes.get()
  client.addVar("blockNumber", $blockNumber)

  let res = waitFor client.sendRequest(ethQuery)
  if res.isErr:
    raise newException(ValueError, res.error)

  let resp = res.get()

  let n = json.parseJson(resp.response)
  if n.hasKey("errors"):
    debugEcho n.pretty
    quit(1)

  let nh = n["data"]["block"]
  let chainId = ChainId.fromJson(n["data"], "chainID")
  result.header = parseBlockHeader(nh)

  if parseTx:
   let txs = nh["transactions"]
   for txn in txs:
     var tx = parseTransaction(txn)
     tx.chainId = chainId
     validateTxSenderAndHash(txn, tx)
     result.body.transactions.add tx

  let uncles = nh["ommers"]
  for un in uncles:
    result.body.uncles.add parseBlockHeader(un)

  waitFor client.closeWait()
