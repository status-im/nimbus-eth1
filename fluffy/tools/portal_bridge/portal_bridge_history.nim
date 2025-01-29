# Fluffy
# Copyright (c) 2024-2025 Status Research & Development GmbH
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
  eth/common/[base, headers_rlp, blocks_rlp, receipts],
  eth/p2p/discoveryv5/random2,
  ../../../nimbus/beacon/web3_eth_conv,
  ../../../hive_integration/nodocker/engine/engine_client,
  ../../rpc/portal_rpc_client,
  ../../network/history/[history_content, history_type_conversions, history_validation],
  ../../network_metadata,
  ../../eth_data/[era1, history_data_ssz_e2s, history_data_seeding],
  ../../database/era1_db,
  ./[portal_bridge_conf, portal_bridge_common]

from stew/objects import checkedEnumAssign
from eth/common/eth_types_rlp import rlpHash

const newHeadPollInterval = 6.seconds # Slot with potential block is every 12s

type PortalHistoryBridge = ref object
  portalClient: RpcClient
  web3Client: RpcClient
  gossipQueue: AsyncQueue[(seq[byte], seq[byte])]

## Conversion functions for Block and Receipts

func asEthBlock(blockObject: BlockObject): EthBlock =
  let
    header = blockObject.toBlockHeader()
    transactions = toTransactions(blockObject.transactions)

  EthBlock(
    header: header, transactions: transactions, withdrawals: blockObject.withdrawals
  )

func asPortalBlockBody(ethBlock: EthBlock): PortalBlockBodyShanghai =
  var transactions: Transactions
  for tx in ethBlock.txs:
    discard transactions.add(TransactionByteList(rlp.encode(tx)))

  var withdrawals: Withdrawals
  doAssert ethBlock.withdrawals.isSome() # TODO: always the case? also when empty?
  for w in ethBlock.withdrawals.get():
    discard withdrawals.add(WithdrawalByteList(rlp.encode(w)))

  PortalBlockBodyShanghai(
    transactions: transactions, uncles: Uncles(@[byte 0xc0]), withdrawals: withdrawals
  )

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
    bridge: PortalHistoryBridge,
    id: Hash32 | uint64,
    headerWithProof: BlockHeaderWithProof,
): Future[void] {.async: (raises: [CancelledError]).} =
  let contentKey = blockHeaderContentKey(id)

  await bridge.gossipQueue.addLast(
    (contentKey.encode.asSeq(), SSZ.encode(headerWithProof))
  )

proc gossipBlockBody(
    bridge: PortalHistoryBridge,
    hash: Hash32,
    body: PortalBlockBodyLegacy | PortalBlockBodyShanghai,
): Future[void] {.async: (raises: [CancelledError]).} =
  let contentKey = blockBodyContentKey(hash)

  await bridge.gossipQueue.addLast((contentKey.encode.asSeq(), SSZ.encode(body)))

proc gossipReceipts(
    bridge: PortalHistoryBridge, hash: Hash32, receipts: PortalReceipts
): Future[void] {.async: (raises: [CancelledError]).} =
  let contentKey = receiptsContentKey(hash)

  await bridge.gossipQueue.addLast((contentKey.encode.asSeq(), SSZ.encode(receipts)))

proc gossipEphemeralBlockHeader(
    bridge: PortalHistoryBridge, hash: Hash32, header: ByteList[MAX_HEADER_LENGTH]
): Future[void] {.async: (raises: [CancelledError]).} =
  let contentKey = ephemeralBlockHeaderContentKey(hash, 0'u8)

  await bridge.gossipQueue.addLast(
    (contentKey.encode.asSeq(), SSZ.encode(EphemeralBlockHeaderList.init(@[header])))
  )

proc runLatestLoop(
    bridge: PortalHistoryBridge, validate = false
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
    let blockObject = (await bridge.web3Client.getBlockByNumber(blockId)).valueOr:
      error "Failed to get latest block", error
      await sleepAsync(1.seconds)
      continue

    let blockNumber = distinctBase(blockObject.number)
    if blockNumber > lastBlockNumber:
      let receiptObjects = (await bridge.web3Client.getBlockReceipts(blockNumber)).valueOr:
        error "Failed to get latest receipts", error
        await sleepAsync(1.seconds)
        continue

      let
        ethBlock = blockObject.asEthBlock()
        header = ByteList[MAX_HEADER_LENGTH].init(rlp.encode(ethBlock.header))
        body = ethBlock.asPortalBlockBody()

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
        if validateHeaderBytes(header.asSeq(), hash).isErr():
          error "Block header is invalid"
          continue
        if validateBlockBody(body, ethBlock.header).isErr():
          error "Block body is invalid"
          continue
        if validateReceipts(portalReceipts, ethBlock.header.receiptsRoot).isErr():
          error "Receipts root is invalid"
          continue

      # gossip ephemeral block header
      await bridge.gossipEphemeralBlockHeader(hash, header)

      # For bodies & receipts to get verified, the header needs to be available
      # on the network. Wait a little to get the headers propagated through
      # the network.
      await sleepAsync(2.seconds)

      # gossip block body
      await bridge.gossipBlockBody(hash, body)
      # gossip receipts
      await bridge.gossipReceipts(hash, portalReceipts)

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
    bridge: PortalHistoryBridge,
    era1File: string,
    epochRecordFile: Opt[string] = Opt.none(string),
    verifyEra = false,
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let f = ?Era1File.open(era1File)

  if verifyEra:
    let _ = ?f.verify()

  # Note: building the accumulator takes about 150ms vs 10ms for reading it,
  # so it is probably not really worth using the read version considering the
  # UX hassle it adds to provide the accumulator ssz files.
  let epochRecord =
    if epochRecordFile.isNone:
      info "Building accumulator from era1 file", era1File
      ?f.buildAccumulator()
    else:
      ?readEpochRecordCached(epochRecordFile.get())

  info "Gossip headers from era1 file", era1File

  for blockHeader in f.era1BlockHeaders:
    doAssert blockHeader.isPreMerge()

    let
      headerWithProof = buildHeaderWithProof(blockHeader, epochRecord).valueOr:
        raiseAssert "Failed to build header with proof: " & $blockHeader.number
      blockHash = blockHeader.rlpHash()

    # gossip block header by hash
    await bridge.gossipBlockHeader(blockHash, headerWithProof)
    # gossip block header by number
    await bridge.gossipBlockHeader(blockHeader.number, headerWithProof)

  info "Succesfully put headers from era1 file in gossip queue", era1File
  ok()

proc gossipBlockContent(
    bridge: PortalHistoryBridge, era1File: string, verifyEra = false
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let f = ?Era1File.open(era1File)

  if verifyEra:
    let _ = ?f.verify()

  info "Gossip bodies and receipts from era1 file", era1File

  for (header, body, receipts, _) in f.era1BlockTuples:
    let blockHash = header.rlpHash()

    # gossip block body
    await bridge.gossipBlockBody(blockHash, PortalBlockBodyLegacy.fromBlockBody(body))
    # gossip receipts
    await bridge.gossipReceipts(blockHash, PortalReceipts.fromReceipts(receipts))

  info "Succesfully put bodies and receipts from era1 file in gossip queue", era1File
  ok()

proc runBackfillLoop(
    bridge: PortalHistoryBridge, era1Dir: string, startEra: uint64, endEra: uint64
) {.async: (raises: [CancelledError]).} =
  let accumulator = loadAccumulator()

  for era in startEra .. endEra:
    let
      root = accumulator.historicalEpochs[era]
      era1File = era1Dir / era1FileName("mainnet", Era1(era), Digest(data: root))

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
      info "Gossip headers from era1 file", era1File
      let headerRes =
        try:
          await bridge.portalClient.portal_debug_historyGossipHeaders(era1File)
        except CatchableError as e:
          error "JSON-RPC portal_debug_historyGossipHeaders failed", error = e.msg
          false

      if headerRes:
        info "Gossip block content from era1 file", era1File
        let res =
          try:
            await bridge.portalClient.portal_debug_historyGossipBlockContent(era1File)
          except CatchableError as e:
            error "JSON-RPC portal_debug_historyGossipBlockContent failed",
              error = e.msg
            false
        if res:
          error "Failed to gossip block content from era1 file", era1File
      else:
        error "Failed to gossip headers from era1 file", era1File
    else:
      (await bridge.gossipHeadersWithProof(era1File)).isOkOr:
        error "Failed to gossip headers from era1 file", error, era1File
        continue

      (await bridge.gossipBlockContent(era1File)).isOkOr:
        error "Failed to gossip block content from era1 file", error, era1File
        continue

proc runBackfillLoopAuditMode(
    bridge: PortalHistoryBridge, era1Dir: string
) {.async: (raises: [CancelledError]).} =
  let
    rng = newRng()
    db = Era1DB.new(era1Dir, "mainnet", loadAccumulator())

  var blockTuple: BlockTuple
  while true:
    let
      # Grab a random blockNumber to audit and potentially gossip
      blockNumber = rng[].rand(network_metadata.mergeBlockNumber - 1).uint64
    db.getBlockTuple(blockNumber, blockTuple).isOkOr:
      error "Failed to get block tuple", error, blockNumber
      continue
    let blockHash = blockTuple.header.rlpHash()

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
              await bridge.portalClient.portal_historyGetContent(
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
              await bridge.portalClient.portal_historyGetContent(
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

      validateBlockBodyBytes(content, blockTuple.header).isOkOr:
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
              await bridge.portalClient.portal_historyGetContent(
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

      validateReceiptsBytes(content, blockTuple.header.receiptsRoot).isOkOr:
        error "Block receipts are invalid", error
        break receiptsBlock

      info "Retrieved block receipts from Portal network"
      receiptsSuccess = true

    # Gossip missing content
    if not headerSuccess:
      let
        epochRecord = db.getAccumulator(blockNumber).valueOr:
          raiseAssert "Failed to get accumulator from EraDB: " & error
        headerWithProof = buildHeaderWithProof(blockTuple.header, epochRecord).valueOr:
          raiseAssert "Failed to build header with proof: " & error

      # gossip block header by hash
      await bridge.gossipBlockHeader(blockHash, headerWithProof)
      # gossip block header by number
      await bridge.gossipBlockHeader(blockNumber, headerWithProof)
    if not bodySuccess:
      await bridge.gossipBlockBody(
        blockHash, PortalBlockBodyLegacy.fromBlockBody(blockTuple.body)
      )
    if not receiptsSuccess:
      await bridge.gossipReceipts(
        blockHash, PortalReceipts.fromReceipts(blockTuple.receipts)
      )

    await sleepAsync(2.seconds)

proc runHistory*(config: PortalBridgeConf) =
  let bridge = PortalHistoryBridge(
    portalClient: newRpcClientConnect(config.portalRpcUrl),
    web3Client: newRpcClientConnect(config.web3Url),
    gossipQueue: newAsyncQueue[(seq[byte], seq[byte])](config.gossipConcurrency),
  )

  proc gossipWorker(bridge: PortalHistoryBridge) {.async: (raises: []).} =
    try:
      while true:
        let
          (contentKey, contentValue) = await bridge.gossipQueue.popFirst()
          contentKeyHex = contentKey.toHex()
          contentValueHex = contentValue.toHex()

        try:
          let peers = await bridge.portalClient.portal_historyPutContent(
            contentKeyHex, contentValueHex
          )
          debug "Content gossiped", peers, contentKey = contentKeyHex
        except CancelledError as e:
          trace "Cancelled gossipWorker"
          raise e
        except CatchableError as e:
          error "JSON-RPC portal_historyPutContent failed",
            error = $e.msg, contentKey = contentKeyHex
    except CancelledError:
      trace "gossipWorker canceled"

  var workers: seq[Future[void]] = @[]
  for i in 0 ..< config.gossipConcurrency:
    workers.add bridge.gossipWorker()

  if config.latest:
    asyncSpawn bridge.runLatestLoop(config.blockVerify)

  if config.backfill:
    if config.audit:
      asyncSpawn bridge.runBackfillLoopAuditMode(config.era1Dir.string)
    else:
      asyncSpawn bridge.runBackfillLoop(
        config.era1Dir.string, config.startEra, config.endEra
      )
