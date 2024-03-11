# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronos,
  chronicles,
  web3/[eth_api, eth_api_types],
  results,
  stew/byteutils,
  eth/common/[eth_types, eth_types_rlp],
  ../../../nimbus/beacon/web3_eth_conv,
  ../../../hive_integration/nodocker/engine/engine_client,
  ../../rpc/[portal_rpc_client],
  ../../network/history/[history_content, history_network],
  ./portal_bridge_conf

from stew/objects import checkedEnumAssign

const newHeadPollInterval = 6.seconds # Slot with potential block is every 12s

## Conversion functions for Block and Receipts

func asEthBlock(blockObject: BlockObject): EthBlock =
  let
    header = blockObject.toBlockHeader()
    transactions = toTransactions(blockObject.transactions)
    withdrawals = toWithdrawals(blockObject.withdrawals)

  EthBlock(header: header, txs: transactions, withdrawals: withdrawals)

func asPortalBlock(
    ethBlock: EthBlock
): (BlockHeaderWithProof, PortalBlockBodyShanghai) =
  var transactions: Transactions
  for tx in ethBlock.txs:
    discard transactions.add(TransactionByteList(rlp.encode(tx)))

  var withdrawals: Withdrawals
  doAssert ethBlock.withdrawals.isSome() # TODO: always the case? also when empty?
  for w in ethBlock.withdrawals.get():
    discard withdrawals.add(WithdrawalByteList(rlp.encode(w)))

  let
    headerWithProof = BlockHeaderWithProof(
      header: ByteList(rlp.encode(ethBlock.header)), proof: BlockHeaderProof.init()
    )
    portalBody = PortalBlockBodyShanghai(
      transactions: transactions, uncles: Uncles(@[byte 0xc0]), withdrawals: withdrawals
    )

  (headerWithProof, portalBody)

func asTxType(quantity: Option[Quantity]): Result[TxType, string] =
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
      var topics: seq[eth_types.Topic]
      for topic in log.topics:
        topics.add(eth_types.Topic(topic))

      logs.add(Log(address: ethAddr log.address, data: log.data, topics: topics))

  let cumulativeGasUsed = receiptObject.cumulativeGasUsed.GasInt
  if receiptObject.status.isSome():
    let status = receiptObject.status.get().int
    ok(
      Receipt(
        receiptType: receiptType,
        isHash: false,
        status: status == 1,
        cumulativeGasUsed: cumulativeGasUsed,
        bloom: BloomFilter(receiptObject.logsBloom),
        logs: logs,
      )
    )
  elif receiptObject.root.isSome():
    ok(
      Receipt(
        receiptType: receiptType,
        isHash: true,
        hash: ethHash receiptObject.root.get(),
        cumulativeGasUsed: cumulativeGasUsed,
        bloom: BloomFilter(receiptObject.logsBloom),
        logs: logs,
      )
    )
  else:
    err("No root nor status field in the JSON receipt object")

func asReceipts(receiptObjects: seq[ReceiptObject]): Result[seq[Receipt], string] =
  var receipts: seq[Receipt]
  for receiptObject in receiptObjects:
    let receipt = asReceipt(receiptObject).valueOr:
      return err(error)
    receipts.add(receipt)

  ok(receipts)

## EL JSON-RPC API helper calls for requesting block and receipts

proc getBlockByNumber(
    client: RpcClient, blockTag: RtBlockIdentifier, fullTransactions: bool = true
): Future[Result[BlockObject, string]] {.async: (raises: []).} =
  let blck =
    try:
      let res = await client.eth_getBlockByNumber(blockTag, fullTransactions)
      if res.isNil:
        return err("failed to get latest blockHeader")

      res
    except CatchableError as e:
      return err("JSON-RPC eth_getBlockByNumber failed: " & e.msg)

  return ok(blck)

proc getBlockReceipts(
    client: RpcClient, blockNumber: uint64
): Future[Result[seq[ReceiptObject], string]] {.async: (raises: []).} =
  let res =
    try:
      await client.eth_getBlockReceipts(blockNumber)
    except CatchableError as e:
      return err("JSON-RPC eth_getBlockReceipts failed: " & e.msg)
  if res.isNone():
    err("Failed getting receipts")
  else:
    ok(res.get())

## Portal JSON-RPC API helper calls for pushing block and receipts

proc gossipBlockHeader(
    client: RpcClient,
    hash: common_types.BlockHash,
    headerWithProof: BlockHeaderWithProof,
): Future[Result[void, string]] {.async: (raises: []).} =
  let
    contentKey = history_content.ContentKey.init(blockHeader, hash)
    encodedContentKeyHex = contentKey.encode.asSeq().toHex()

    peers =
      try:
        await client.portal_historyGossip(
          encodedContentKeyHex, SSZ.encode(headerWithProof).toHex()
        )
      except CatchableError as e:
        return err("JSON-RPC error: " & $e.msg)

  info "Block header gossiped", peers, contentKey = encodedContentKeyHex
  return ok()

proc gossipBlockBody(
    client: RpcClient, hash: common_types.BlockHash, body: PortalBlockBodyShanghai
): Future[Result[void, string]] {.async: (raises: []).} =
  let
    contentKey = history_content.ContentKey.init(blockBody, hash)
    encodedContentKeyHex = contentKey.encode.asSeq().toHex()

    peers =
      try:
        await client.portal_historyGossip(
          encodedContentKeyHex, SSZ.encode(body).toHex()
        )
      except CatchableError as e:
        return err("JSON-RPC error: " & $e.msg)

  info "Block body gossiped", peers, contentKey = encodedContentKeyHex
  return ok()

proc gossipReceipts(
    client: RpcClient, hash: common_types.BlockHash, receipts: PortalReceipts
): Future[Result[void, string]] {.async: (raises: []).} =
  let
    contentKey =
      history_content.ContentKey.init(history_content.ContentType.receipts, hash)
    encodedContentKeyHex = contentKey.encode.asSeq().toHex()

    peers =
      try:
        await client.portal_historyGossip(
          encodedContentKeyHex, SSZ.encode(receipts).toHex()
        )
      except CatchableError as e:
        return err("JSON-RPC error: " & $e.msg)

  info "Receipts gossiped", peers, contentKey = encodedContentKeyHex
  return ok()

proc runLatestLoop(
    portalClient: RpcClient, web3Client: RpcClient, validate = false
) {.async: (raises: [CancelledError]).} =
  ## Loop that requests the latest block + receipts and pushes them into the
  ## Portal network.
  ## Current strategy is to poll for the latest block and receipts, and then
  ## convert the data (optionally verify it) and push it into the Portal network.
  ## If the EL JSON-RPC API calls fail, 1 second is waited before retrying.
  ## If the Portal JSON-RPC API calls fail, the error is logged and the loop
  ## continues.
  ## TODO: Might want to add retries on Portal JSON-RPC API call failures too.
  ## TODO: Investigate Portal side JSON-RPC error seen:
  ## "JSON-RPC error: Request Entity Too Large"
  let blockId = blockId("latest")
  var lastBlockNumber = 0'u64
  while true:
    let t0 = Moment.now()
    let blockObject = (await getBlockByNumber(web3Client, blockId)).valueOr:
      error "Failed to get latest block", error
      await sleepAsync(1.seconds)
      continue

    let blockNumber = distinctBase(blockObject.number)
    if blockNumber > lastBlockNumber:
      let receiptObjects = (await web3Client.getBlockReceipts(blockNumber)).valueOr:
        error "Failed to get latest receipts", error
        await sleepAsync(1.seconds)
        continue

      let
        ethBlock = blockObject.asEthBlock()
        (headerWithProof, body) = ethBlock.asPortalBlock()

        receipts = receiptObjects.asReceipts().valueOr:
          # Note: this failure should not occur. It would mean invalid encoded
          # receipts by provider
          error "Error converting JSON RPC receipt objects", error
          await sleepAsync(1.seconds)
          continue
        portalReceipts = PortalReceipts.fromReceipts(receipts)

      lastBlockNumber = blockNumber

      let hash = common_types.BlockHash(data: distinctBase(blockObject.hash))
      if validate:
        if validateBlockHeaderBytes(headerWithProof.header.asSeq(), hash).isErr():
          error "Block header is invalid"
          continue
        if validateBlockBody(body, ethBlock.header).isErr():
          error "Block body is invalid"
          continue
        if validateReceipts(portalReceipts, ethBlock.header.receiptRoot).isErr():
          error "Receipts root is invalid"
          continue

      # gossip block header
      (await portalClient.gossipBlockHeader(hash, headerWithProof)).isOkOr:
        error "Failed to gossip block header", error

      # For bodies & receipts to get verified, the header needs to be available
      # on the network. Wait a little to get the headers propagated through
      # the network.
      await sleepAsync(2.seconds)

      # gossip block body
      (await portalClient.gossipBlockBody(hash, body)).isOkOr:
        error "Failed to gossip block body", error

      # gossip receipts
      (await portalClient.gossipReceipts(hash, portalReceipts)).isOkOr:
        error "Failed to gossip receipts", error

    # Making sure here that we poll enough times not to miss a block.
    # We could also do some work without awaiting it, e.g. the gossiping or
    # the requesting the receipts during the sleep time. But we also want to
    # avoid creating a backlog of requests or gossip.
    let t1 = Moment.now()
    let elapsed = t1 - t0
    if elapsed < newHeadPollInterval:
      await sleepAsync(newHeadPollInterval - elapsed)
    else:
      warn "Block gossip took longer than the poll interval"

proc runHistory*(config: PortalBridgeConf) =
  let
    portalClient = newRpcHttpClient()
    # TODO: Use Web3 object?
    web3Client: RpcClient =
      case config.web3Url.kind
      of HttpUrl:
        newRpcHttpClient()
      of WsUrl:
        newRpcWebSocketClient()
  try:
    waitFor portalClient.connect(config.rpcAddress, Port(config.rpcPort), false)
  except CatchableError as e:
    error "Failed to connect to portal RPC", error = $e.msg

  if config.web3Url.kind == HttpUrl:
    try:
      waitFor (RpcHttpClient(web3Client)).connect(config.web3Url.url)
    except CatchableError as e:
      error "Failed to connect to web3 RPC", error = $e.msg

  asyncSpawn runLatestLoop(portalClient, web3Client, config.blockVerify)

  while true:
    poll()
