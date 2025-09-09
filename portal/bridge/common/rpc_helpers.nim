# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  json_rpc/rpcclient,
  web3/[eth_api, eth_api_types],
  ../nimbus_portal_bridge_conf

from stew/objects import checkedEnumAssign
from ../../../hive_integration/nodocker/engine/engine_client import
  toBlockHeader, toTransactions

export rpcclient

proc newRpcClientConnect*(url: JsonRpcUrl): RpcClient =
  ## Instantiate a new JSON-RPC client and try to connect. Will quit on failure.
  case url.kind
  of HttpUrl:
    let client = newRpcHttpClient()
    try:
      waitFor client.connect(url.value)
    except CatchableError as e:
      fatal "Failed to connect to JSON-RPC server", error = $e.msg, url = url.value
      quit QuitFailure
    client
  of WsUrl:
    let client = newRpcWebSocketClient()
    try:
      waitFor client.connect(url.value)
    except CatchableError as e:
      warn "Failed to connect to JSON-RPC server", error = $e.msg, url = url.value
      # The Websocket client supports reconnecting so we don't need to quit here
      #quit QuitFailure
    client

proc tryReconnect*(client: RpcClient, url: JsonRpcUrl) {.async: (raises: []).} =
  if url.kind == WsUrl:
    doAssert client of RpcWebSocketClient

    let wsClient = RpcWebSocketClient(client)
    if wsClient.transport.isNil:
      # disconnected
      try:
        await wsClient.connect(url.value)
      except CatchableError as e:
        warn "Failed to reconnect to JSON-RPC server", error = $e.msg, url = url.value

func asTxType(quantity: Opt[Quantity]): Result[TxType, string] =
  let value = quantity.get(0.Quantity).uint8
  var txType: TxType
  if not checkedEnumAssign(txType, value):
    err("Invalid data for TxType: " & $value)
  else:
    ok(txType)

func asReceipt(receiptObject: ReceiptObject): Result[Receipt, string] =
  let receiptType = asTxType(receiptObject.`type`).valueOr:
    return err("Failed conversion to TxType" & error)

  var logs: seq[Log]
  if receiptObject.logs.len > 0:
    for log in receiptObject.logs:
      var topics: seq[receipts.Topic]
      for topic in log.topics:
        topics.add(topic)

      logs.add(Log(address: log.address, data: log.data, topics: topics))

  let cumulativeGasUsed = receiptObject.cumulativeGasUsed.GasInt
  if receiptObject.status.isSome():
    let status = receiptObject.status.get().int
    ok(
      Receipt(
        receiptType: receiptType,
        isHash: false,
        status: status == 1,
        cumulativeGasUsed: cumulativeGasUsed,
        logsBloom: Bloom(receiptObject.logsBloom),
        logs: logs,
      )
    )
  elif receiptObject.root.isSome():
    ok(
      Receipt(
        receiptType: receiptType,
        isHash: true,
        hash: receiptObject.root.get(),
        cumulativeGasUsed: cumulativeGasUsed,
        logsBloom: Bloom(receiptObject.logsBloom),
        logs: logs,
      )
    )
  else:
    err("No root nor status field in the JSON receipt object")

func asReceipts*(receiptObjects: seq[ReceiptObject]): Result[seq[Receipt], string] =
  var receipts: seq[Receipt]
  for receiptObject in receiptObjects:
    let receipt = asReceipt(receiptObject).valueOr:
      return err(error)
    receipts.add(receipt)

  ok(receipts)

proc getHeaderByNumber*(
    client: RpcClient, blockId: BlockIdentifier
): Future[Result[Header, string]] {.async: (raises: [CancelledError]).} =
  let blockObject =
    try:
      await client.eth_getBlockByNumber(blockId, fullTransactions = false)
    except CatchableError as e:
      return err(e.msg)

  ok(blockObject.toBlockHeader())

proc getBlockByNumber*(
    client: RpcClient, blockId: BlockIdentifier
): Future[Result[(Header, BlockBody, UInt256), string]] {.
    async: (raises: [CancelledError])
.} =
  let blockObject =
    try:
      await client.eth_getBlockByNumber(blockId, fullTransactions = true)
    except CatchableError as e:
      return err(e.msg)

  var uncles: seq[Header]
  for i in 0 ..< blockObject.uncles.len:
    let uncleBlockObject =
      try:
        await client.eth_getUncleByBlockNumberAndIndex(blockId, Quantity(i))
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
    client: RpcClient, blockId: BlockIdentifier
): Future[Result[seq[Receipt], string]] {.async: (raises: [CancelledError]).} =
  let receiptsObjects =
    try:
      await client.eth_getBlockReceipts(blockId)
    except CatchableError as e:
      return err(e.msg)

  if receiptsObjects.isNone():
    return err("No receipts found for block number " & $blockId)

  receiptsObjects.value().asReceipts()

proc getStoredReceiptsByNumber*(
    client: RpcClient, blockId: BlockIdentifier
): Future[Result[seq[StoredReceipt], string]] {.async: (raises: [CancelledError]).} =
  ok((?(await client.getReceiptsByNumber(blockId))).to(seq[StoredReceipt]))
