# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  stew/byteutils,
  json_rpc/rpcclient,
  web3/[eth_api_types, eth_api],
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  ../../eth_data/yaml_utils

from ../../../hive_integration/nodocker/engine/engine_client import
  toBlockHeader, toTransactions
from ../../bridge/history/portal_history_bridge import asReceipts

type BlockData* = object
  header*: string
  body*: string
  receipts*: string

proc getHeaderByNumber*(
    client: RpcClient, blockNumber: uint64
): Future[Result[Header, string]] {.async: (raises: [CancelledError]).} =
  let blockObject =
    try:
      await client.eth_getBlockByNumber(blockId(blockNumber), fullTransactions = false)
    except CatchableError as e:
      return err(e.msg)

  ok(blockObject.toBlockHeader())

proc getBlockByNumber*(
    client: RpcClient, blockNumber: uint64
): Future[Result[(Header, BlockBody, UInt256), string]] {.
    async: (raises: [CancelledError])
.} =
  let blockObject =
    try:
      await client.eth_getBlockByNumber(blockId(blockNumber), fullTransactions = true)
    except CatchableError as e:
      return err(e.msg)

  var uncles: seq[Header]
  for i in 0 ..< blockObject.uncles.len:
    let uncleBlockObject =
      try:
        await client.eth_getUncleByBlockNumberAndIndex(
          blockId(blockNumber), Quantity(i)
        )
      except CatchableError as e:
        return err(e.msg)

    uncles.add(uncleBlockObject.toBlockHeader())

  ok(
    (
      blockObject.toBlockHeader(),
      BlockBody(
        transactions: blockObject.transactions.toTransactions(),
        uncles: uncles,
        withdrawals: blockObject.withdrawals,
      ),
      blockObject.totalDifficulty,
    )
  )

proc getReceiptsByNumber*(
    client: RpcClient, blockNumber: uint64
): Future[Result[seq[Receipt], string]] {.async: (raises: [CancelledError]).} =
  let receiptsObjects =
    try:
      await client.eth_getBlockReceipts(blockId(blockNumber))
    except CatchableError as e:
      return err(e.msg)

  if receiptsObjects.isNone():
    return err("No receipts found for block number " & $blockNumber)

  receiptsObjects.value().asReceipts()

proc toBlockData(header: Header, body: BlockBody, receipts: seq[Receipt]): BlockData =
  BlockData(
    header: rlp.encode(header).to0xHex(),
    body: rlp.encode(body).to0xHex(),
    receipts: rlp.encode(receipts).to0xHex(),
  )

proc exportBlock*(
    client: RpcClient, blockNumber: uint64, fileName: string
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let
    (header, body, _) = ?(await client.getBlockByNumber(blockNumber))
    receipts = ?(await client.getReceiptsByNumber(blockNumber))

  toBlockData(header, body, receipts).dumpToYaml(fileName)
