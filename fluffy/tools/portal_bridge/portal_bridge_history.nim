# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  chronos,
  chronicles,
  web3/[eth_api, eth_api_types],
  results,
  stew/byteutils,
  eth/common/keys,
  eth/common/[base, headers_rlp, blocks_rlp],
  eth/p2p/discoveryv5/random2,
  ../../../nimbus/beacon/web3_eth_conv,
  ../../../hive_integration/nodocker/engine/engine_client,
  ../../rpc/portal_rpc_client,
  ../../network/history/[history_content, history_network],
  ../../network_metadata,
  ../../eth_data/[era1, history_data_ssz_e2s, history_data_seeding],
  ../../database/era1_db,
  ./[portal_bridge_conf, portal_bridge_common]

from stew/objects import checkedEnumAssign
from eth/common/eth_types_rlp import rlpHash

const newHeadPollInterval = 6.seconds # Slot with potential block is every 12s

## Conversion functions for Block and Receipts

func asEthBlock(blockObject: BlockObject): EthBlock =
  let
    header = blockObject.toBlockHeader()
    transactions = toTransactions(blockObject.transactions)
    withdrawals = toWithdrawals(blockObject.withdrawals)

  EthBlock(header: header, transactions: transactions, withdrawals: withdrawals)

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
      header: ByteList[2048](rlp.encode(ethBlock.header)),
      proof: BlockHeaderProof.init(),
    )
    portalBody = PortalBlockBodyShanghai(
      transactions: transactions, uncles: Uncles(@[byte 0xc0]), withdrawals: withdrawals
    )

  (headerWithProof, portalBody)

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

func asReceipts(receiptObjects: seq[ReceiptObject]): Result[seq[Receipt], string] =
  var receipts: seq[Receipt]
  for receiptObject in receiptObjects:
    let receipt = asReceipt(receiptObject).valueOr:
      return err(error)
    receipts.add(receipt)

  ok(receipts)

## EL JSON-RPC API helper calls for requesting block and receipts

proc getBlockReceipts(
    client: RpcClient, blockNumber: uint64
): Future[Result[seq[ReceiptObject], string]] {.async: (raises: []).} =
  let res =
    try:
      await client.eth_getBlockReceipts(blockId(blockNumber))
    except CatchableError as e:
      return err("EL JSON-RPC eth_getBlockReceipts failed: " & e.msg)
  if res.isNone():
    err("EL failed to provided requested receipts")
  else:
    ok(res.get())

## Portal JSON-RPC API helper calls for pushing block and receipts

proc gossipBlockHeader(
    client: RpcClient, id: Hash32 | uint64, headerWithProof: BlockHeaderWithProof
): Future[Result[void, string]] {.async: (raises: []).} =
  let
    contentKey = blockHeaderContentKey(id)
    encodedContentKeyHex = contentKey.encode.asSeq().toHex()

    peers =
      try:
        await client.portal_historyGossip(
          encodedContentKeyHex, SSZ.encode(headerWithProof).toHex()
        )
      except CatchableError as e:
        return err("JSON-RPC portal_historyGossip failed: " & $e.msg)

  info "Block header gossiped", peers, contentKey = encodedContentKeyHex
  return ok()

proc gossipBlockBody(
    client: RpcClient,
    hash: Hash32,
    body: PortalBlockBodyLegacy | PortalBlockBodyShanghai,
): Future[Result[void, string]] {.async: (raises: []).} =
  let
    contentKey = blockBodyContentKey(hash)
    encodedContentKeyHex = contentKey.encode.asSeq().toHex()

    peers =
      try:
        await client.portal_historyGossip(
          encodedContentKeyHex, SSZ.encode(body).toHex()
        )
      except CatchableError as e:
        return err("JSON-RPC portal_historyGossip failed: " & $e.msg)

  info "Block body gossiped", peers, contentKey = encodedContentKeyHex
  return ok()

proc gossipReceipts(
    client: RpcClient, hash: Hash32, receipts: PortalReceipts
): Future[Result[void, string]] {.async: (raises: []).} =
  let
    contentKey = receiptsContentKey(hash)
    encodedContentKeyHex = contentKey.encode.asSeq().toHex()

    peers =
      try:
        await client.portal_historyGossip(
          encodedContentKeyHex, SSZ.encode(receipts).toHex()
        )
      except CatchableError as e:
        return err("JSON-RPC portal_historyGossip failed: " & $e.msg)

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

      let hash = blockObject.hash
      if validate:
        if validateBlockHeaderBytes(headerWithProof.header.asSeq(), hash).isErr():
          error "Block header is invalid"
          continue
        if validateBlockBody(body, ethBlock.header).isErr():
          error "Block body is invalid"
          continue
        if validateReceipts(portalReceipts, ethBlock.header.receiptsRoot).isErr():
          error "Receipts root is invalid"
          continue

      # gossip block header by hash
      (await portalClient.gossipBlockHeader(hash, headerWithProof)).isOkOr:
        error "Failed to gossip block header", error, hash
      # gossip block header by number
      (await portalClient.gossipBlockHeader(blockNumber, headerWithProof)).isOkOr:
        error "Failed to gossip block header", error, hash

      # For bodies & receipts to get verified, the header needs to be available
      # on the network. Wait a little to get the headers propagated through
      # the network.
      await sleepAsync(2.seconds)

      # gossip block body
      (await portalClient.gossipBlockBody(hash, body)).isOkOr:
        error "Failed to gossip block body", error, hash

      # gossip receipts
      (await portalClient.gossipReceipts(hash, portalReceipts)).isOkOr:
        error "Failed to gossip receipts", error, hash

    # Making sure here that we poll enough times not to miss a block.
    # We could also do some work without awaiting it, e.g. the gossiping or
    # the requesting the receipts during the sleep time. But we also want to
    # avoid creating a backlog of requests or gossip.
    let t1 = Moment.now()
    let elapsed = t1 - t0
    if elapsed < newHeadPollInterval:
      await sleepAsync(newHeadPollInterval - elapsed)
    elif elapsed > newHeadPollInterval * 2:
      warn "Block gossip took longer than slot interval"

proc gossipHeadersWithProof(
    portalClient: RpcClient,
    era1File: string,
    epochRecordFile: Opt[string] = Opt.none(string),
    verifyEra = false,
): Future[Result[void, string]] {.async: (raises: []).} =
  let f = ?Era1File.open(era1File)

  if verifyEra:
    let _ = ?f.verify()

  # Note: building the accumulator takes about 150ms vs 10ms for reading it,
  # so it is probably not really worth using the read version considering the
  # UX hassle it adds to provide the accumulator ssz files.
  let epochRecord =
    if epochRecordFile.isNone:
      ?f.buildAccumulator()
    else:
      ?readEpochRecordCached(epochRecordFile.get())

  for (contentKey, contentValue) in f.headersWithProof(epochRecord):
    let peers =
      try:
        await portalClient.portal_historyGossip(
          contentKey.asSeq.toHex(), contentValue.toHex()
        )
      except CatchableError as e:
        return err("JSON-RPC portal_historyGossip failed: " & $e.msg)
    info "Block header gossiped", peers, contentKey

  ok()

proc gossipBlockContent(
    portalClient: RpcClient, era1File: string, verifyEra = false
): Future[Result[void, string]] {.async: (raises: []).} =
  let f = ?Era1File.open(era1File)

  if verifyEra:
    let _ = ?f.verify()

  for (contentKey, contentValue) in f.blockContent():
    let peers =
      try:
        await portalClient.portal_historyGossip(
          contentKey.asSeq.toHex(), contentValue.toHex()
        )
      except CatchableError as e:
        return err("JSON-RPC portal_historyGossip failed: " & $e.msg)
    info "Block content gossiped", peers, contentKey

  ok()

proc runBackfillLoop(
    portalClient: RpcClient, web3Client: RpcClient, era1Dir: string
) {.async: (raises: [CancelledError]).} =
  let
    rng = newRng()
    accumulator = loadAccumulator()
  while true:
    let
      # Grab a random era1 to backfill
      era = rng[].rand(int(era(network_metadata.mergeBlockNumber - 1)))
      root = accumulator.historicalEpochs[era]
      eraFile = era1Dir / era1FileName("mainnet", Era1(era), Digest(data: root))

    # Note:
    # There are two design options here:
    # 1. Provide the Era1 file through the fluffy custom debug API and let
    # fluffy process the Era1 file and gossip the content from there.
    # 2. Process the Era1 files in the bridge and call the
    # standardized gossip JSON-RPC method.
    #
    # Option 2. is more conceptually clean and compatible due to no usage of
    # custom API, however it will involve invoking a lot of JSON-RPC calls
    # to pass along block data (in hex).
    # Option 2. is used here. Switch to Option 1. can be made in case efficiency
    # turns out the be a problem. It is however a bit more tricky to know when a
    # new era1 can be gossiped (might need another custom json-rpc that checks
    # the offer queue)
    when false:
      info "Gossip headers from era1 file", eraFile
      let headerRes =
        try:
          await portalClient.portal_debug_historyGossipHeaders(eraFile)
        except CatchableError as e:
          error "JSON-RPC portal_debug_historyGossipHeaders failed", error = e.msg
          false

      if headerRes:
        info "Gossip block content from era1 file", eraFile
        let res =
          try:
            await portalClient.portal_debug_historyGossipBlockContent(eraFile)
          except CatchableError as e:
            error "JSON-RPC portal_debug_historyGossipBlockContent failed",
              error = e.msg
            false
        if res:
          error "Failed to gossip block content from era1 file", eraFile
      else:
        error "Failed to gossip headers from era1 file", eraFile
    else:
      info "Gossip headers from era1 file", eraFile
      (await portalClient.gossipHeadersWithProof(eraFile)).isOkOr:
        error "Failed to gossip headers from era1 file", error, eraFile
        continue

      info "Gossip block content from era1 file", eraFile
      (await portalClient.gossipBlockContent(eraFile)).isOkOr:
        error "Failed to gossip block content from era1 file", error, eraFile
        continue

      info "Succesfully gossiped era1 file", eraFile

proc runBackfillLoopAuditMode(
    portalClient: RpcClient, web3Client: RpcClient, era1Dir: string
) {.async: (raises: [CancelledError]).} =
  let
    rng = newRng()
    db = Era1DB.new(era1Dir, "mainnet", loadAccumulator())

  while true:
    let
      # Grab a random blockNumber to audit and potentially gossip
      blockNumber = rng[].rand(network_metadata.mergeBlockNumber - 1).uint64
      (header, body, receipts, _) = db.getBlockTuple(blockNumber).valueOr:
        error "Failed to get block tuple", error, blockNumber
        continue
      blockHash = header.rlpHash()

    var headerSuccess, bodySuccess, receiptsSuccess = false

    logScope:
      blockNumber = blockNumber

    # header
    block headerBlock:
      let
        contentKey = blockHeaderContentKey(blockHash)
        contentHex =
          try:
            (
              await portalClient.portal_historyRecursiveFindContent(
                contentKey.encode.asSeq().toHex()
              )
            ).content
          except CatchableError as e:
            error "Failed to find block header content", error = e.msg
            break headerBlock
        content =
          try:
            hexToSeqByte(contentHex)
          except ValueError as e:
            error "Invalid hex for block header content", error = e.msg
            break headerBlock

        headerWithProof = decodeSsz(content, BlockHeaderWithProof).valueOr:
          error "Failed to decode block header content", error
          break headerBlock

      if keccak256(headerWithProof.header.asSeq()) != blockHash:
        error "Block hash mismatch", blockNumber
        break headerBlock

      info "Retrieved block header from Portal network", blockHash
      headerSuccess = true

    # body
    block bodyBlock:
      let
        contentKey = blockBodyContentKey(blockHash)
        contentHex =
          try:
            (
              await portalClient.portal_historyRecursiveFindContent(
                contentKey.encode.asSeq().toHex()
              )
            ).content
          except CatchableError as e:
            error "Failed to find block body content", error = e.msg
            break bodyBlock
        content =
          try:
            hexToSeqByte(contentHex)
          except ValueError as e:
            error "Invalid hex for block body content", error = e.msg
            break bodyBlock

      validateBlockBodyBytes(content, header).isOkOr:
        error "Block body is invalid", error
        break bodyBlock

      info "Retrieved block body from Portal network"
      bodySuccess = true

    # receipts
    block receiptsBlock:
      let
        contentKey = receiptsContentKey(blockHash)
        contentHex =
          try:
            (
              await portalClient.portal_historyRecursiveFindContent(
                contentKey.encode.asSeq().toHex()
              )
            ).content
          except CatchableError as e:
            error "Failed to find block receipts content", error = e.msg
            break receiptsBlock
        content =
          try:
            hexToSeqByte(contentHex)
          except ValueError as e:
            error "Invalid hex for block receipts content", error = e.msg
            break receiptsBlock

      validateReceiptsBytes(content, header.receiptsRoot).isOkOr:
        error "Block receipts are invalid", error
        break receiptsBlock

      info "Retrieved block receipts from Portal network"
      receiptsSuccess = true

    # Gossip missing content
    if not headerSuccess:
      let
        epochRecord = db.getAccumulator(blockNumber).valueOr:
          raiseAssert "Failed to get accumulator from EraDB: " & error
        headerWithProof = buildHeaderWithProof(header, epochRecord).valueOr:
          raiseAssert "Failed to build header with proof: " & error

      # gossip block header by hash
      (await portalClient.gossipBlockHeader(blockHash, headerWithProof)).isOkOr:
        error "Failed to gossip block header", error, blockHash
      # gossip block header by number
      (await portalClient.gossipBlockHeader(blockNumber, headerWithProof)).isOkOr:
        error "Failed to gossip block header", error, blockHash
    if not bodySuccess:
      (
        await portalClient.gossipBlockBody(
          blockHash, PortalBlockBodyLegacy.fromBlockBody(body)
        )
      ).isOkOr:
        error "Failed to gossip block body", error, blockHash
    if not receiptsSuccess:
      (
        await portalClient.gossipReceipts(
          blockHash, PortalReceipts.fromReceipts(receipts)
        )
      ).isOkOr:
        error "Failed to gossip receipts", error, blockHash

    await sleepAsync(2.seconds)

proc runHistory*(config: PortalBridgeConf) =
  let
    portalClient = newRpcClientConnect(config.portalRpcUrl)
    web3Client = newRpcClientConnect(config.web3Url)

  if config.latest:
    asyncSpawn runLatestLoop(portalClient, web3Client, config.blockVerify)

  if config.backfill:
    if config.audit:
      asyncSpawn runBackfillLoopAuditMode(
        portalClient, web3Client, config.era1Dir.string
      )
    else:
      asyncSpawn runBackfillLoop(portalClient, web3Client, config.era1Dir.string)

  while true:
    poll()
