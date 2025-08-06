# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push gcsafe, raises: [].}

import
  unittest2,
  web3/[eth_api, eth_api_types],
  stew/io2,
  json_rpc/[rpcclient, rpcserver, rpcproxy, jsonmarshal],
  eth/common/eth_types_rlp,
  ../rpc/transactions,
  ./test_setup,
  ./test_api_backend

proc getBlockFromJson(filepath: string): BlockObject =
  var blkBytes = readAllBytes(filepath)
  let blk = JrpcConv.decode(blkBytes.get, BlockObject)
  return blk

template checkEqual(tx1: TransactionObject, tx2: TransactionObject): bool =
  JrpcConv.encode(tx1).JsonString == JrpcConv.encode(tx2).JsonString

suite "test transaction verification":
  test "check tx hash":
    let blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Istanbul.json")
    for tx in blk.transactions:
      if tx.kind == TxOrHashKind.tohTx:
        check checkTxHash(tx.tx, tx.tx.hash)

  test "check tx trie root":
    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Istanbul.json")
      res = verifyTransactions(blk.transactionsRoot, blk.transactions)

    check res.isOk()

  test "check eth api methods":
    let
      ts = TestApiState.init(1.u256)
      vp = startTestSetup(ts, 1, 1, 8888)
        # defining port 8888 is a hack for addr in use errors
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")

    for tx in blk.transactions:
      if tx.kind == tohTx:
        ts.loadTransaction(tx.tx.hash, tx.tx)
        let verifiedTx =
          waitFor vp.proxy.getClient().eth_getTransactionByHash(tx.tx.hash)
        check checkEqual(verifiedTx, tx.tx)
        ts.clear()

    vp.stopTestSetup()
