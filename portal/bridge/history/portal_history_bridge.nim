# Nimbus
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
  ../../../execution_chain/beacon/web3_eth_conv,
  ../../../hive_integration/engine_client,
  ../../rpc/portal_rpc_client,
  ../../network/history/[history_content, history_validation],
  ../../eth_history/block_proofs/historical_hashes_accumulator,
  ../../eth_history/[era1, history_data_ssz_e2s],
  ../../database/era1_db,
  ../../../execution_chain/common/[hardforks, chain_config],
  ../common/rpc_helpers,
  ../nimbus_portal_bridge_conf

from ../../network/network_metadata import loadAccumulator

const newHeadPollInterval = 6.seconds # Slot with potential block is every 12s

type PortalHistoryBridge = ref object
  portalClient: RpcClient
  web3Client: RpcClient
  gossipQueue: AsyncQueue[(seq[byte], seq[byte])]
  cfg*: ChainConfig

proc gossipBlockBody(
    bridge: PortalHistoryBridge, blockNumber: uint64, body: BlockBody
): Future[void] {.async: (raises: [CancelledError]).} =
  let contentKey = blockBodyContentKey(blockNumber)

  await bridge.gossipQueue.addLast((contentKey.encode.asSeq(), rlp.encode(body)))

proc gossipReceipts(
    bridge: PortalHistoryBridge, blockNumber: uint64, receipts: StoredReceipts
): Future[void] {.async: (raises: [CancelledError]).} =
  let contentKey = receiptsContentKey(blockNumber)

  await bridge.gossipQueue.addLast((contentKey.encode.asSeq(), rlp.encode(receipts)))

proc runLatestLoop(
    bridge: PortalHistoryBridge, validate = false
) {.async: (raises: [CancelledError]).} =
  ## Loop that requests the latest block body + receipts and pushes them into the
  ## Portal network.
  ## Current strategy is to poll for the latest block and receipts, and then
  ## convert the data (optionally verify it) and push it into the Portal network.
  ## If the EL JSON-RPC API calls fail, 1 second is waited before retrying.
  ## If the Portal JSON-RPC API calls fail, the error is logged and the loop
  ## continues.
  let blockId = blockId("latest")
  var lastBlockNumber = 0'u64
  while true:
    let t0 = Moment.now()
    let (header, body, _) = (await bridge.web3Client.getBlockByNumber(blockId)).valueOr:
      error "Failed to get latest block", error
      await sleepAsync(1.seconds)
      continue

    let blockNumber = header.number
    if blockNumber > lastBlockNumber:
      let receipts = (
        await bridge.web3Client.getStoredReceiptsByNumber(blockId(blockNumber))
      ).valueOr:
        error "Failed to get latest receipts", error
        await sleepAsync(1.seconds)
        continue

      if validate:
        validateContent(body, header).isOkOr:
          error "Block body is invalid", error
          continue
        validateContent(receipts, header).isOkOr:
          error "Receipts is invalid", error
          continue

      lastBlockNumber = blockNumber

      # gossip block body
      await bridge.gossipBlockBody(blockNumber, body)
      # gossip receipts
      await bridge.gossipReceipts(blockNumber, receipts)

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

proc gossipBlockContent(
    bridge: PortalHistoryBridge, era1File: string, verifyEra = false
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let f = ?Era1File.open(era1File, bridge.cfg.posBlock.get())

  if verifyEra:
    let _ = ?f.verify()

  info "Gossip bodies and receipts from era1 file", era1File

  for (header, body, receipts, _) in f.era1BlockTuples:
    let blockNumber = header.number

    # gossip block body
    await bridge.gossipBlockBody(blockNumber, body)
    # gossip receipts
    await bridge.gossipReceipts(blockNumber, receipts.to(StoredReceipts))

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

    (await bridge.gossipBlockContent(era1File)).isOkOr:
      error "Failed to gossip block content from era1 file", error, era1File
      continue

proc runBackfillLoopAuditMode(
    bridge: PortalHistoryBridge, era1Dir: string, startEra: uint64, endEra: uint64
) {.async: (raises: [CancelledError]).} =
  let
    rng = newRng()
    db = Era1DB.new(era1Dir, "mainnet", loadAccumulator(), bridge.cfg.posBlock.get())
    blockLowerBound = startEra * EPOCH_SIZE # inclusive
    blockUpperBound = ((endEra + 1) * EPOCH_SIZE) - 1 # inclusive
    blockRange = blockUpperBound - blockLowerBound

  var blockTuple: BlockTuple
  while true:
    # Grab a random blockNumber to audit and potentially gossip
    let blockNumber = blockLowerBound + rng[].rand(blockRange).uint64

    logScope:
      blockNumber = blockNumber

    db.getBlockTuple(blockNumber, blockTuple).isOkOr:
      error "Failed to get block tuple", error
      continue

    var bodySuccess, receiptsSuccess = false

    # body
    block bodyBlock:
      let _ =
        try:
          (
            await bridge.portalClient.portal_historyGetBlockBody(
              rlp.encode(blockTuple.header).to0xHex()
            )
          )
        except CatchableError as e:
          error "Failed to find block body content", error = e.msg
          break bodyBlock

      info "Retrieved block body from Portal network"
      bodySuccess = true

    # receipts
    block receiptsBlock:
      let _ =
        try:
          (
            await bridge.portalClient.portal_historyGetReceipts(
              rlp.encode(blockTuple.header).to0xHex()
            )
          )
        except CatchableError as e:
          error "Failed to find block receipts content", error = e.msg
          break receiptsBlock

      info "Retrieved block receipts from Portal network"
      receiptsSuccess = true

    # Gossip missing content
    if not bodySuccess:
      await bridge.gossipBlockBody(blockNumber, blockTuple.body)
    if not receiptsSuccess:
      await bridge.gossipReceipts(blockNumber, blockTuple.receipts.to(StoredReceipts))

    await sleepAsync(2.seconds)

proc runHistory*(config: PortalBridgeConf) =
  let bridge = PortalHistoryBridge(
    portalClient: newRpcClientConnect(config.portalRpcUrl),
    web3Client: newRpcClientConnect(config.web3Url),
    gossipQueue: newAsyncQueue[(seq[byte], seq[byte])](config.gossipConcurrency),
    cfg: chainConfigForNetwork(MainNet),
  )

  proc gossipWorker(bridge: PortalHistoryBridge) {.async: (raises: []).} =
    try:
      while true:
        let
          (contentKey, contentValue) = await bridge.gossipQueue.popFirst()
          contentKeyHex = contentKey.toHex()
          contentValueHex = contentValue.toHex()

        while true:
          try:
            let putContentResult = await bridge.portalClient.portal_historyPutContent(
              contentKeyHex, contentValueHex
            )
            let
              peers = putContentResult.peerCount
              accepted = putContentResult.acceptMetadata.acceptedCount
              alreadyStored = putContentResult.acceptMetadata.alreadyStoredCount
              notWithinRadius = putContentResult.acceptMetadata.notWithinRadiusCount
              genericDecline = putContentResult.acceptMetadata.genericDeclineCount
              rateLimited = putContentResult.acceptMetadata.rateLimitedCount
              transferInProgress =
                putContentResult.acceptMetadata.transferInProgressCount

            logScope:
              contentKey = contentKeyHex

            debug "Content gossiped",
              peers, accepted, genericDecline, alreadyStored, notWithinRadius,
              rateLimited, transferInProgress

            # Conditions below are assumed on correct and non malicious behavior of the peers.
            if peers == genericDecline + rateLimited + transferInProgress:
              # No peers accepted or already stored the content.
              # Decline reasons are likely temporary, so retry.
              warn "All peers declined, rate limited, or transfer in progress; retrying...",
                contentKey = contentKeyHex
              # Sleep 5 seconds to back off a bit before retrying
              await sleepAsync(5.seconds)
              # Note i: might want to introduce exponential backoff here
              # Note ii: Due to the fact that consecutive block numbers have consecutive content
              # ids until the hash function wraps around, it is likely that (some of) the same peers
              # will be selected for the next content and thus remain busy. A potential improvement
              # could be to stream content from multiple "content id ranges".
              continue

            if peers == notWithinRadius:
              # No peers were found within radius. Retrying is unlikely to help,
              # as new searches probably won't find peers in radius. This is a
              # network-wide issue due to insufficient storage.
              warn "No peers were found within radius for content",
                contentKey = contentKeyHex
              break

            if accepted + alreadyStored >= 1:
              # At least one peer either accepted or already has the content,
              # data should be in the network.
              debug "At least one peer accepted or already stored the content"
              break
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
      asyncSpawn bridge.runBackfillLoopAuditMode(
        config.era1Dir.string, config.startEra, config.endEra
      )
    else:
      asyncSpawn bridge.runBackfillLoop(
        config.era1Dir.string, config.startEra, config.endEra
      )
