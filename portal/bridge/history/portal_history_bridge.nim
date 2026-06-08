# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
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
  ../../../execution_chain/history/db/ere_db,
  ../common/rpc_helpers,
  ../nimbus_portal_bridge_conf,
  beacon_chain/process_state,
  ./portal_history_bridge_common,
  ./portal_history_bridge_legacy

const newHeadPollInterval = 6.seconds # Slot with potential block is every 12s

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

proc runBackfillLoop(
    bridge: PortalHistoryBridge,
    ereDir: string,
    startEra: uint64,
    endEra: uint64,
    loop: bool,
) {.async: (raises: [CancelledError]).} =
  let db = EreDB.init(ereDir, "mainnet", mergeBlockNumber(MainNet)).valueOr:
    fatal "Could not open ere database", ereDir, error = error
    ProcessState.scheduleStop("ere_db_error")
    return
  defer:
    db.dispose()

  let lastEra = min(endEra, db.lastEra())

  while true:
    for era in startEra .. lastEra:
      let
        blockStart = Era(era).startNumber()
        blockEnd = Era(era).endNumber()

      info "Gossiping bodies and receipts from ere", era, blockStart, blockEnd

      for blockNumber in blockStart .. blockEnd:
        var body: BlockBody
        db.getBlockBody(blockNumber, body).isOkOr:
          error "Failed to get block body from ere", blockNumber, error
          continue

        var receipts: seq[StoredReceipt]
        db.getReceipts(blockNumber, receipts).isOkOr:
          error "Failed to get receipts from ere", blockNumber, error
          continue

        await bridge.gossipBlockBody(blockNumber, body)
        await bridge.gossipReceipts(blockNumber, receipts)

      info "Completed gossiping from ere", era

    if not loop:
      ProcessState.scheduleStop("backfill_complete")
      break

    info "Completed backfill loop, starting over"

proc runBackfillLoopSyncMode(
    bridge: PortalHistoryBridge,
    ereDir: string,
    startEra: uint64,
    endEra: uint64,
    loop: bool,
) {.async: (raises: [CancelledError]).} =
  let
    db = EreDB.init(ereDir, "mainnet", mergeBlockNumber(MainNet)).valueOr:
      fatal "Could not open ere database", ereDir, error = error
      ProcessState.scheduleStop("ere_db_error")
      return
    lastEra = min(endEra, db.lastEra())
    blockStart = Era(startEra).startNumber()
    blockEnd = Era(lastEra).endNumber()
    blockNumberQueue = newAsyncQueue[uint64](50)
  defer:
    db.dispose()

  proc blockWorker() {.async: (raises: [CancelledError]).} =
    while true:
      let blockNumber = await blockNumberQueue.popFirst()

      logScope:
        blockNumber = blockNumber

      var
        header: Header
        body: BlockBody
        receipts: seq[StoredReceipt]
      db.getBlockHeader(blockNumber, header).isOkOr:
        error "Failed to get block header from ere", error
        continue
      db.getBlockBody(blockNumber, body).isOkOr:
        error "Failed to get block body from ere", error
        continue
      db.getReceipts(blockNumber, receipts).isOkOr:
        error "Failed to get receipts from ere", error
        continue

      block bodyBlock:
        let _ = (await historyGetBlockBody(bridge.portalClient, header)).valueOr:
          debug "Failed to find block body content, gossiping..", error = $error.message
          await bridge.gossipBlockBody(blockNumber, body)
          break bodyBlock

      block receiptsBlock:
        let _ = (await historyGetReceipts(bridge.portalClient, header)).valueOr:
          debug "Failed to find block receipts content, gossiping..",
            error = $error.message
          await bridge.gossipReceipts(blockNumber, receipts)
          break receiptsBlock

  var workers: seq[Future[void]] = @[]
  for i in 0 ..< 50:
    workers.add blockWorker()

  while true:
    for blockNumber in blockStart .. blockEnd:
      if blockNumber mod MaxEreSize == 0:
        info "Backfilling task at block", blockNumber, era = blockNumber div MaxEreSize

      await blockNumberQueue.addLast(blockNumber)

    if not loop:
      ProcessState.scheduleStop("backfill_complete")
      break

    info "Completed backfill loop, starting over"

proc runBackfillLoopAuditMode(
    bridge: PortalHistoryBridge, ereDir: string, startEra: uint64, endEra: uint64
) {.async: (raises: [CancelledError]).} =
  let
    rng = newRng()
    db = EreDB.init(ereDir, "mainnet", mergeBlockNumber(MainNet)).valueOr:
      fatal "Could not open ere database", ereDir, error = error
      ProcessState.scheduleStop("ere_db_error")
      return
    lastEra = min(endEra, db.lastEra())
    blockStart = Era(startEra).startNumber()
    blockEnd = Era(lastEra).endNumber()
    blockRange = blockEnd - blockStart
  defer:
    db.dispose()

  var
    header: Header
    body: BlockBody
    receipts: seq[StoredReceipt]
  while true:
    let blockNumber = blockStart + rng[].rand(blockRange).uint64

    logScope:
      blockNumber = blockNumber

    db.getBlockHeader(blockNumber, header).isOkOr:
      error "Failed to get block header from ere", error
      continue
    db.getBlockBody(blockNumber, body).isOkOr:
      error "Failed to get block body from ere", error
      continue
    db.getReceipts(blockNumber, receipts).isOkOr:
      error "Failed to get receipts from ere", error
      continue

    block bodyBlock:
      let _ = (await historyGetBlockBody(bridge.portalClient, header)).valueOr:
        info "Failed to find block body content, gossiping..", error = $error
        await bridge.gossipBlockBody(blockNumber, body)
        break bodyBlock

    block receiptsBlock:
      let _ = (await historyGetReceipts(bridge.portalClient, header)).valueOr:
        info "Failed to find block receipts content, gossiping..", error = $error
        await bridge.gossipReceipts(blockNumber, receipts)
        break receiptsBlock

    await sleepAsync(1.seconds)

proc runHistory*(config: PortalBridgeConf) =
  let bridge = PortalHistoryBridge(
    portalClient: PortalRpcClient.init(newRpcClientConnect(config.portalRpcUrl)),
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
            let putContentResult = await RpcClient(bridge.portalClient)
              .portal_historyPutContent(contentKeyHex, contentValueHex)
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
              debug "All peers declined, rate limited, or transfer in progress; retrying...",
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

  let
    startEra = config.era
    endEra =
      if config.eraCount == 0:
        high(uint64)
      else:
        config.era + config.eraCount - 1

  case config.backfillMode
  of BackfillMode.none:
    if not config.latest:
      ProcessState.scheduleStop("no_backfill_no_latest")
  of BackfillMode.regular, BackfillMode.sync, BackfillMode.audit:
    if config.ereDir.isSome:
      let ereDir = config.ereDir.get().string
      case config.backfillMode
      of BackfillMode.regular:
        asyncSpawn bridge.runBackfillLoop(ereDir, startEra, endEra, config.backfillLoop)
      of BackfillMode.sync:
        asyncSpawn bridge.runBackfillLoopSyncMode(
          ereDir, startEra, endEra, config.backfillLoop
        )
      of BackfillMode.audit:
        asyncSpawn bridge.runBackfillLoopAuditMode(ereDir, startEra, endEra)
      else:
        discard
    elif config.era1Dir.isSome:
      let era1Dir = config.era1Dir.get().string
      case config.backfillMode
      of BackfillMode.regular:
        asyncSpawn bridge.runBackfillLoopLegacy(
          era1Dir, startEra, endEra, config.backfillLoop
        )
      of BackfillMode.sync:
        asyncSpawn bridge.runBackfillLoopSyncModeLegacy(
          era1Dir, startEra, endEra, config.backfillLoop
        )
      of BackfillMode.audit:
        asyncSpawn bridge.runBackfillLoopAuditModeLegacy(era1Dir, startEra, endEra)
      else:
        discard
    else:
      fatal "Backfill mode requires --ere-dir or --era1-dir to be set"
      quit(QuitFailure)
