# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## The beacon_lc_bridge is a "standalone" bridge, which means that it requires
## only a Portal client to inject content into the Portal network, but retrieves
## the content via p2p protocols only (no private / centralized full node access
## required).
## The bridge allows to follow the head of the beacon chain and inject the latest
## execution block headers and bodies into the Portal history network.
## It can, optionally, inject the beacon LC content into the Portal beacon network.
##
## The bridge does consensus light client sync and follows beacon block gossip.
## Once it is synced, the execution payload of new beacon blocks will be
## extracted and injected in the Portal network as execution headers and blocks.
##
## The injection into the Portal network is done via the `portal_historyGossip`
## JSON-RPC endpoint of a running Fluffy node.
##
## Actions that this type of bridge (currently?) cannot perform:
## 1. Inject block receipts into the portal network
## 2. Inject epoch accumulators into the portal network
## 3. Backfill headers and blocks
## 4. Provide proofs for the headers
##
## - To provide 1., it would require devp2p/eth access for the bridge to remain
## standalone.
## - To provide 2., it could use Era1 files.
## - To provide 3. and 4, it could use Era1 files pre-merge, and Era files
## post-merge. To backfill without Era or Era1 files, it could use libp2p and
## devp2p for access to the blocks, however it would not be possible to (easily)
## build the proofs for the headers.

{.push raises: [].}

import
  std/[os, strutils],
  chronicles,
  chronos,
  confutils,
  eth/[rlp, trie/ordered_trie],
  eth/common/keys,
  eth/common/[base, headers_rlp, blocks_rlp],
  beacon_chain/el/[el_manager, engine_api_conversions],
  beacon_chain/gossip_processing/optimistic_processor,
  beacon_chain/networking/[eth2_network, topic_params],
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/[light_client, nimbus_binary_common],
  # Weirdness. Need to import this to be able to do errors.ValidationResult as
  # else we get an ambiguous identifier, ValidationResult from eth & libp2p.
  libp2p/protocols/pubsub/errors,
  ../../rpc/portal_rpc_client,
  ../../network/history/[history_content, history_network],
  ../../network/beacon/beacon_content,
  ../../common/common_types,
  ./beacon_lc_bridge_conf

from beacon_chain/gossip_processing/block_processor import newExecutionPayload
from beacon_chain/gossip_processing/eth2_processor import toValidationResult

template append(w: var RlpWriter, t: TypedTransaction) =
  w.appendRawBytes(distinctBase t)

template append(w: var RlpWriter, t: WithdrawalV1) =
  # TODO: Since Capella we can also access ExecutionPayloadHeader and thus
  # could get the Roots through there instead.
  w.append blocks.Withdrawal(
    index: distinctBase(t.index),
    validatorIndex: distinctBase(t.validatorIndex),
    address: t.address,
    amount: distinctBase(t.amount),
  )

proc asPortalBlockData*(
    payload: ExecutionPayloadV1
): (Hash32, BlockHeaderWithProof, PortalBlockBodyLegacy) =
  let
    txRoot = orderedTrieRoot(payload.transactions)

    header = Header(
      parentHash: payload.parentHash,
      ommersHash: EMPTY_UNCLE_HASH,
      coinbase: EthAddress payload.feeRecipient,
      stateRoot: payload.stateRoot,
      transactionsRoot: txRoot,
      receiptsRoot: payload.receiptsRoot,
      logsBloom: distinctBase(payload.logsBloom).to(Bloom),
      difficulty: default(DifficultyInt),
      number: payload.blockNumber.distinctBase,
      gasLimit: distinctBase(payload.gasLimit),
      gasUsed: distinctBase(payload.gasUsed),
      timestamp: payload.timestamp.EthTime,
      extraData: payload.extraData.data,
      mixHash: payload.prevRandao,
      nonce: default(Bytes8),
      baseFeePerGas: Opt.some(payload.baseFeePerGas),
      withdrawalsRoot: Opt.none(Hash32),
      blobGasUsed: Opt.none(uint64),
      excessBlobGas: Opt.none(uint64),
    )

    headerWithProof = BlockHeaderWithProof(
      header: ByteList[2048](rlp.encode(header)), proof: BlockHeaderProof.init()
    )

  var transactions: Transactions
  for tx in payload.transactions:
    discard transactions.add(TransactionByteList(distinctBase(tx)))

  let body =
    PortalBlockBodyLegacy(transactions: transactions, uncles: Uncles(@[byte 0xc0]))

  (payload.blockHash, headerWithProof, body)

proc asPortalBlockData*(
    payload: ExecutionPayloadV2 | ExecutionPayloadV3 | ExecutionPayloadV4
): (Hash32, BlockHeaderWithProof, PortalBlockBodyShanghai) =
  let
    txRoot = orderedTrieRoot(payload.transactions)
    withdrawalsRoot = Opt.some(orderedTrieRoot(payload.withdrawals))

    # TODO: adjust blobGasUsed & excessBlobGas according to deneb fork!
    header = Header(
      parentHash: payload.parentHash,
      ommersHash: EMPTY_UNCLE_HASH,
      coinbase: EthAddress payload.feeRecipient,
      stateRoot: payload.stateRoot,
      transactionsRoot: txRoot,
      receiptsRoot: payload.receiptsRoot,
      logsBloom: distinctBase(payload.logsBloom).to(Bloom),
      difficulty: default(DifficultyInt),
      number: payload.blockNumber.distinctBase,
      gasLimit: distinctBase(payload.gasLimit),
      gasUsed: distinctBase(payload.gasUsed),
      timestamp: payload.timestamp.EthTime,
      extraData: payload.extraData.data,
      mixHash: payload.prevRandao,
      nonce: default(Bytes8),
      baseFeePerGas: Opt.some(payload.baseFeePerGas),
      withdrawalsRoot: withdrawalsRoot,
      blobGasUsed: Opt.none(uint64),
      excessBlobGas: Opt.none(uint64),
    )

    headerWithProof = BlockHeaderWithProof(
      header: ByteList[2048](rlp.encode(header)), proof: BlockHeaderProof.init()
    )

  var transactions: Transactions
  for tx in payload.transactions:
    discard transactions.add(TransactionByteList(distinctBase(tx)))

  func toWithdrawal(x: WithdrawalV1): Withdrawal =
    Withdrawal(
      index: x.index.uint64,
      validatorIndex: x.validatorIndex.uint64,
      address: x.address.EthAddress,
      amount: x.amount.uint64,
    )

  var withdrawals: Withdrawals
  for w in payload.withdrawals:
    discard withdrawals.add(WithdrawalByteList(rlp.encode(toWithdrawal(w))))

  let body = PortalBlockBodyShanghai(
    transactions: transactions, uncles: Uncles(@[byte 0xc0]), withdrawals: withdrawals
  )

  (payload.blockHash, headerWithProof, body)

proc run(config: BeaconBridgeConf) {.raises: [CatchableError].} =
  # Required as both Eth2Node and LightClient requires correct config type
  var lcConfig = config.asLightClientConf()

  setupLogging(config.logLevel, config.logStdout, none(OutFile))

  notice "Launching fluffy beacon chain light bridge",
    cmdParams = commandLineParams(), config

  let metadata = loadEth2Network(config.eth2Network)

  for node in metadata.bootstrapNodes:
    lcConfig.bootstrapNodes.add node

  template cfg(): auto =
    metadata.cfg

  let
    genesisState =
      try:
        template genesisData(): auto =
          metadata.genesis.bakedBytes

        newClone(
          readSszForkedHashedBeaconState(
            cfg, genesisData.toOpenArray(genesisData.low, genesisData.high)
          )
        )
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    genesisTime = getStateField(genesisState[], genesis_time)
    beaconClock = BeaconClock.init(genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit QuitFailure

    getBeaconTime = beaconClock.getBeaconTimeFn()

    genesis_validators_root = getStateField(genesisState[], genesis_validators_root)
    forkDigests = newClone ForkDigests.init(cfg, genesis_validators_root)

    genesisBlockRoot = get_initial_beacon_block(genesisState[]).root

    rng = keys.newRng()

    netKeys = getRandomNetKeys(rng[])

    network = createEth2Node(
      rng, lcConfig, netKeys, cfg, forkDigests, getBeaconTime, genesis_validators_root
    )

    portalRpcClient = newRpcHttpClient()

    optimisticHandler = proc(
        signedBlock: ForkedSignedBeaconBlock
    ): Future[void] {.async: (raises: [CancelledError]).} =
      # TODO: Should not be gossiping optimistic blocks, but instead store them
      # in a cache and only gossip them after they are confirmed due to an LC
      # finalized header.
      notice "New LC optimistic block",
        opt = signedBlock.toBlockId(), wallSlot = getBeaconTime().slotOrZero

      withBlck(signedBlock):
        when consensusFork >= ConsensusFork.Bellatrix:
          if forkyBlck.message.is_execution_block:
            template payload(): auto =
              forkyBlck.message.body

            # TODO: Get rid of the asEngineExecutionPayload step?
            let executionPayload = payload.asEngineExecutionPayload()
            let (hash, headerWithProof, body) = asPortalBlockData(executionPayload)

            logScope:
              blockhash = history_content.`$` hash

            block: # gossip header
              let contentKey = blockHeaderContentKey(hash)
              let encodedContentKey = contentKey.encode.asSeq()

              try:
                let peers = await portalRpcClient.portal_historyGossip(
                  toHex(encodedContentKey), SSZ.encode(headerWithProof).toHex()
                )
                info "Block header gossiped",
                  peers, contentKey = encodedContentKey.toHex()
              except CatchableError as e:
                error "JSON-RPC error", error = $e.msg
              # TODO: clean-up when json-rpc gets async raises annotations
              try:
                await portalRpcClient.close()
              except CatchableError:
                discard

            # For bodies to get verified, the header needs to be available on
            # the network. Wait a little to get the headers propagated through
            # the network.
            await sleepAsync(2.seconds)

            block: # gossip block
              let contentKey = blockBodyContentKey(hash)
              let encodedContentKey = contentKey.encode.asSeq()

              try:
                let peers = await portalRpcClient.portal_historyGossip(
                  encodedContentKey.toHex(), SSZ.encode(body).toHex()
                )
                info "Block body gossiped",
                  peers, contentKey = encodedContentKey.toHex()
              except CatchableError as e:
                error "JSON-RPC error", error = $e.msg

              # TODO: clean-up when json-rpc gets async raises annotations
              try:
                await portalRpcClient.close()
              except CatchableError:
                discard

      return

    optimisticProcessor = initOptimisticProcessor(getBeaconTime, optimisticHandler)

    lightClient = createLightClient(
      network, rng, lcConfig, cfg, forkDigests, getBeaconTime, genesis_validators_root,
      LightClientFinalizationMode.Optimistic,
    )

  ### Beacon Light Client content bridging specific callbacks
  proc onBootstrap(lightClient: LightClient, bootstrap: ForkedLightClientBootstrap) =
    withForkyObject(bootstrap):
      when lcDataFork > LightClientDataFork.None:
        info "New Beacon LC bootstrap",
          forkyObject, slot = forkyObject.header.beacon.slot

        let
          root = hash_tree_root(forkyObject.header)
          contentKey = encode(bootstrapContentKey(root))
          forkDigest =
            forkDigestAtEpoch(forkDigests[], epoch(forkyObject.header.beacon.slot), cfg)
          content = encodeBootstrapForked(forkDigest, bootstrap)

        proc GossipRpcAndClose() {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconGossip(
                contentKeyHex, content.toHex()
              )
            info "Beacon LC bootstrap gossiped", peers, contentKey = contentKeyHex
          except CatchableError as e:
            error "JSON-RPC error", error = $e.msg

          await portalRpcClient.close()

        asyncSpawn(GossipRpcAndClose())

  proc onUpdate(lightClient: LightClient, update: ForkedLightClientUpdate) =
    withForkyObject(update):
      when lcDataFork > LightClientDataFork.None:
        info "New Beacon LC update",
          update, slot = forkyObject.attested_header.beacon.slot

        let
          period = forkyObject.attested_header.beacon.slot.sync_committee_period
          contentKey = encode(updateContentKey(period.uint64, uint64(1)))
          forkDigest = forkDigestAtEpoch(
            forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg
          )
          content = encodeLightClientUpdatesForked(forkDigest, @[update])

        proc GossipRpcAndClose() {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconGossip(
                contentKeyHex, content.toHex()
              )
            info "Beacon LC bootstrap gossiped", peers, contentKey = contentKeyHex
          except CatchableError as e:
            error "JSON-RPC error", error = $e.msg

          await portalRpcClient.close()

        asyncSpawn(GossipRpcAndClose())

  proc onOptimisticUpdate(
      lightClient: LightClient, update: ForkedLightClientOptimisticUpdate
  ) =
    withForkyObject(update):
      when lcDataFork > LightClientDataFork.None:
        info "New Beacon LC optimistic update",
          update, slot = forkyObject.attested_header.beacon.slot

        let
          slot = forkyObject.signature_slot
          contentKey = encode(optimisticUpdateContentKey(slot.uint64))
          forkDigest = forkDigestAtEpoch(
            forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg
          )
          content = encodeOptimisticUpdateForked(forkDigest, update)

        proc GossipRpcAndClose() {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconGossip(
                contentKeyHex, content.toHex()
              )
            info "Beacon LC bootstrap gossiped", peers, contentKey = contentKeyHex
          except CatchableError as e:
            error "JSON-RPC error", error = $e.msg

          await portalRpcClient.close()

        asyncSpawn(GossipRpcAndClose())

  proc onFinalityUpdate(
      lightClient: LightClient, update: ForkedLightClientFinalityUpdate
  ) =
    withForkyObject(update):
      when lcDataFork > LightClientDataFork.None:
        info "New Beacon LC finality update",
          update, slot = forkyObject.attested_header.beacon.slot
        let
          finalizedSlot = forkyObject.finalized_header.beacon.slot
          contentKey = encode(finalityUpdateContentKey(finalizedSlot.uint64))
          forkDigest = forkDigestAtEpoch(
            forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg
          )
          content = encodeFinalityUpdateForked(forkDigest, update)

        proc GossipRpcAndClose() {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconGossip(
                contentKeyHex, content.toHex()
              )
            info "Beacon LC bootstrap gossiped", peers, contentKey = contentKeyHex
          except CatchableError as e:
            error "JSON-RPC error", error = $e.msg

          await portalRpcClient.close()

        asyncSpawn(GossipRpcAndClose())

  ###

  waitFor portalRpcClient.connect(config.rpcAddress, Port(config.rpcPort), false)

  info "Listening to incoming network requests"
  network.registerProtocol(
    PeerSync,
    PeerSync.NetworkState.init(cfg, forkDigests, genesisBlockRoot, getBeaconTime),
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.phase0),
    proc(signedBlock: phase0.SignedBeaconBlock): errors.ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock)),
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.altair),
    proc(signedBlock: altair.SignedBeaconBlock): errors.ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock)),
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.bellatrix),
    proc(signedBlock: bellatrix.SignedBeaconBlock): errors.ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock)),
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.capella),
    proc(signedBlock: capella.SignedBeaconBlock): errors.ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock)),
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.deneb),
    proc(signedBlock: deneb.SignedBeaconBlock): errors.ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock)),
  )
  lightClient.installMessageValidators()

  waitFor network.startListening()
  waitFor network.start()

  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: ForkedLightClientHeader
  ) =
    withForkyHeader(finalizedHeader):
      when lcDataFork > LightClientDataFork.None:
        info "New LC finalized header", finalized_header = shortLog(forkyHeader)

  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: ForkedLightClientHeader
  ) =
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.None:
        info "New LC optimistic header", optimistic_header = shortLog(forkyHeader)

  lightClient.onFinalizedHeader = onFinalizedHeader
  lightClient.onOptimisticHeader = onOptimisticHeader
  lightClient.trustedBlockRoot = some config.trustedBlockRoot

  if config.beaconLightClient:
    lightClient.bootstrapObserver = onBootstrap
    lightClient.updateObserver = onUpdate
    lightClient.finalityUpdateObserver = onFinalityUpdate
    lightClient.optimisticUpdateObserver = onOptimisticUpdate

  func shouldSyncOptimistically(wallSlot: Slot): bool =
    let optimisticHeader = lightClient.optimisticHeader
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.None:
        # Check whether light client has synced sufficiently close to wall slot
        const maxAge = 2 * SLOTS_PER_EPOCH
        forkyHeader.beacon.slot >= max(wallSlot, maxAge.Slot) - maxAge
      else:
        false

  var blocksGossipState: GossipState = {}
  proc updateBlocksGossipStatus(slot: Slot) =
    let
      isBehind = not shouldSyncOptimistically(slot)

      targetGossipState = getTargetGossipState(
        slot.epoch, cfg.ALTAIR_FORK_EPOCH, cfg.BELLATRIX_FORK_EPOCH,
        cfg.CAPELLA_FORK_EPOCH, cfg.DENEB_FORK_EPOCH, cfg.ELECTRA_FORK_EPOCH, isBehind,
      )

    template currentGossipState(): auto =
      blocksGossipState

    if currentGossipState == targetGossipState:
      return

    if currentGossipState.card == 0 and targetGossipState.card > 0:
      debug "Enabling blocks topic subscriptions", wallSlot = slot, targetGossipState
    elif currentGossipState.card > 0 and targetGossipState.card == 0:
      debug "Disabling blocks topic subscriptions", wallSlot = slot
    else:
      # Individual forks added / removed
      discard

    let
      newGossipForks = targetGossipState - currentGossipState
      oldGossipForks = currentGossipState - targetGossipState

    for gossipFork in oldGossipForks:
      let forkDigest = forkDigests[].atConsensusFork(gossipFork)
      network.unsubscribe(getBeaconBlocksTopic(forkDigest))

    for gossipFork in newGossipForks:
      let forkDigest = forkDigests[].atConsensusFork(gossipFork)
      network.subscribe(
        getBeaconBlocksTopic(forkDigest), blocksTopicParams, enableTopicMetrics = true
      )

    blocksGossipState = targetGossipState

  proc onSecond(time: Moment) =
    let wallSlot = getBeaconTime().slotOrZero()
    updateBlocksGossipStatus(wallSlot + 1)
    lightClient.updateGossipStatus(wallSlot + 1)

  proc runOnSecondLoop() {.async.} =
    let sleepTime = chronos.seconds(1)
    while true:
      let start = chronos.now(chronos.Moment)
      await chronos.sleepAsync(sleepTime)
      let afterSleep = chronos.now(chronos.Moment)
      let sleepTime = afterSleep - start
      onSecond(start)
      let finished = chronos.now(chronos.Moment)
      let processingTime = finished - afterSleep
      trace "onSecond task completed", sleepTime, processingTime

  onSecond(Moment.now())
  lightClient.start()

  asyncSpawn runOnSecondLoop()
  while true:
    poll()

when isMainModule:
  {.pop.}
  var config = makeBannerAndConfig("Nimbus beacon chain bridge", BeaconBridgeConf)
  {.push raises: [].}

  run(config)
