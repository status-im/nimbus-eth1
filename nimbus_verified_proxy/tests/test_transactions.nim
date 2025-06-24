# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  web3/eth_api_types,
  stew/io2,
  json_rpc/jsonmarshal,
  eth/common/eth_types_rlp,
  ../rpc/transactions

proc getBlockFromJson(filepath: string): BlockObject =
  var blkBytes = readAllBytes(filepath)
  let blk = JrpcConv.decode(blkBytes.get, BlockObject)
  debugEcho blk.hash
  return blk

let blk = getBlockFromJson("nimbus_verified_proxy/tests/block.json")

suite "test transaction hashing":
  test "check tx hash":
    for tx in blk.transactions:
      if tx.kind == TxOrHashKind.tohTx:
        check checkTxHash(tx.tx, tx.tx.hash)

  test "check tx trie root":
    let res = verifyTransactions(blk.transactionsRoot, blk.transactions)

    check res.isOk()
