# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#
# This beacon_chain_bridge allows for following the head of the beacon chain and
# seeding the latest execution block headers and bodies into the Portal network.
#
# The bridge does consensus light client sync and follows beacon block gossip.
# Once it is synced, the execution payload of new beacon blocks will be
# extracted and injected in the Portal network as execution headers and blocks.
#
# The injection into the Portal network is done via the `portal_historyGossip`
# JSON-RPC endpoint of a running Fluffy node.
#
# Other, currently not implemented, options to seed data:
# - Backfill post-merge block headers & bodies block into the network. Could
#   walk down the parent blocks and seed them. Could also verify if the data is
#   already available on the network before seeding it, potentially jumping in
#   steps > 1.
# - For backfill of pre-merge headers and blocks, access to epoch accumulators
#   is needed to be able to build the proofs. These could be retrieved from the
#   network, but would require usage of the `portal_historyRecursiveFindContent`
#   JSON-RPC endpoint. Additionally, the actualy block headers and bodies need
#   to be requested from an execution JSON-RPC endpoint.
#   Data would flow from:
#     (block data)          execution client -> bridge
#     (epoch accumulator)   fluffy -> bridge
#     (portal content)      bridge -> fluffy
#   This seems awfully cumbersome. Other options sound better, see comment down.
# - Also receipts need to be requested from an execution JSON-RPC endpoint, but
#   they can be verified because of consensus light client sync.
#   Of course, if you are using a trusted execution endpoint for that, you can
#   get the block headers and bodies also through that channel.
#
# Data seeding of Epoch accumulators is unlikely to be supported by this bridge.
# It is currently done by first downloading and storing all headers into files
# per epoch. Then the accumulator and epoch accumulators can be build from this
# data.
# The reason for this approach is because downloading all the headers from an
# execution endpoint takes long (you actually request the full blocks). An
# intermediate local storage step is preferred because of this. The accumulator
# build itself can be done in minutes when the data is locally available. These
# locally stored accumulators can then be seeded directly from a Fluffy node via
# a (currently) non standardized JSON-RPC endpoint.
#
# Data seeding of the block headers, bodies and receipts can be done the same
# way. Downloading and storing them first locally in files. Then seeding them
# into the network.
# For the headers, the proof needs to be build and added from the right
# epoch accumulator, so access to the epoch accumulator is a requirement
# (offline or from the network).
# This functionality is currently directly part of Fluffy and triggered via
# non standardized JSON-RPC calls
# Alternatively, this could also be moved to a seperate tool which gossips the
# data with a portal_historyGossip JSON-RPC call, but the building of the header
# proofs would be slighty more cumbersome.
#

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[os, strutils, options],
  web3/ethtypes,
  chronicles, chronicles/chronos_tools, chronos,
  eth/[keys, rlp], eth/[trie, trie/db],
  # Need to rename this because of web3 ethtypes and ambigious indentifier mess
  # for `BlockHeader`.
  eth/common/eth_types as etypes,
  eth/common/eth_types_rlp,
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/gossip_processing/optimistic_processor,
  beacon_chain/networking/topic_params,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/[light_client, nimbus_binary_common, version],
  # Weirdness. Need to import this to be able to do errors.ValidationResult as
  # else we get an ambiguous identifier, ValidationResult from eth & libp2p.
  libp2p/protocols/pubsub/errors,
  ../../rpc/portal_rpc_client,
  ../../network/history/history_content,
  ../../common/common_types,
  ./beacon_chain_bridge_conf

from beacon_chain/gossip_processing/block_processor import newExecutionPayload
from beacon_chain/gossip_processing/eth2_processor import toValidationResult

template asEthHash(hash: ethtypes.BlockHash): Hash256 =
  Hash256(data: distinctBase(hash))

# TODO: Ugh why isn't gasLimit and gasUsed a uint64 in nim-eth / nimbus-eth1 :(
template unsafeQuantityToInt64(q: Quantity): int64 =
  int64 q

proc asPortalBlockData*(
    payload: ExecutionPayloadV1 | ExecutionPayloadV2 | ExecutionPayloadV3):
    (common_types.BlockHash, BlockHeaderWithProof, BlockBodySSZ) =
  proc calculateTransactionData(
      items: openArray[TypedTransaction]):
      Hash256 {.raises: [Defect].} =

    var tr = initHexaryTrie(newMemoryDB())
    for i, t in items:
      try:
        let tx = distinctBase(t)
        tr.put(rlp.encode(i), tx)
      except RlpError as e:
        # TODO: Investigate this RlpError as it doesn't sound like this is
        # something that can actually occur.
        raiseAssert(e.msg)

    return tr.rootHash()

  let
    txRoot = calculateTransactionData(payload.transactions)

    # TODO: update according to payload type
    header = etypes.BlockHeader(
      parentHash: payload.parentHash.asEthHash,
      ommersHash: EMPTY_UNCLE_HASH,
      coinbase: EthAddress payload.feeRecipient,
      stateRoot: payload.stateRoot.asEthHash,
      txRoot: txRoot,
      receiptRoot: payload.receiptsRoot.asEthHash,
      bloom: distinctBase(payload.logsBloom),
      difficulty: default(DifficultyInt),
      blockNumber: payload.blockNumber.distinctBase.u256,
      gasLimit: payload.gasLimit.unsafeQuantityToInt64,
      gasUsed: payload.gasUsed.unsafeQuantityToInt64,
      timestamp: fromUnix payload.timestamp.unsafeQuantityToInt64,
      extraData: bytes payload.extraData,
      mixDigest: payload.prevRandao.asEthHash,
      nonce: default(BlockNonce),
      fee: some(payload.baseFeePerGas),
      withdrawalsRoot: options.none(Hash256), # TODO: Update later
      excessDataGas: options.none(UInt256) # TODO: Update later
    )

    headerWithProof = BlockHeaderWithProof(
      header: ByteList(rlp.encode(header)),
      proof: BlockHeaderProof.init())

  var transactions: Transactions
  for tx in payload.transactions:
    discard transactions.add(TransactionByteList(distinctBase(tx)))

  let body = BlockBodySSZ(
    transactions: transactions,
    uncles: Uncles(@[byte 0xc0]))

  let hash = common_types.BlockHash(data: distinctBase(payload.blockHash))

  (hash, headerWithProof, body)

# TODO Find what can throw exception
proc run() {.raises: [Exception, Defect].} =
  {.pop.}
  var config = makeBannerAndConfig(
    "Nimbus beacon chain bridge", BeaconBridgeConf)
  {.push raises: [Defect].}

  # Required as both Eth2Node and LightClient requires correct config type
  var lcConfig = config.asLightClientConf()

  setupLogging(config.logLevel, config.logStdout, none(OutFile))

  notice "Launching Nimbus beacon chain bridge",
    cmdParams = commandLineParams(), config

  let metadata = loadEth2Network(config.eth2Network)

  for node in metadata.bootstrapNodes:
    lcConfig.bootstrapNodes.add node

  template cfg(): auto = metadata.cfg

  let
    genesisState =
      try:
        template genesisData(): auto = metadata.genesisData
        newClone(readSszForkedHashedBeaconState(
          cfg, genesisData.toOpenArrayByte(genesisData.low, genesisData.high)))
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    beaconClock = BeaconClock.init(getStateField(genesisState[], genesis_time))

    getBeaconTime = beaconClock.getBeaconTimeFn()

    genesis_validators_root =
      getStateField(genesisState[], genesis_validators_root)
    forkDigests = newClone ForkDigests.init(cfg, genesis_validators_root)

    genesisBlockRoot = get_initial_beacon_block(genesisState[]).root

    rng = keys.newRng()

    netKeys = getRandomNetKeys(rng[])

    network = createEth2Node(
      rng, lcConfig, netKeys, cfg,
      forkDigests, getBeaconTime, genesis_validators_root
    )

    rpcHttpclient = newRpcHttpClient()

    optimisticHandler = proc(signedBlock: ForkedMsgTrustedSignedBeaconBlock):
        Future[void] {.async.} =
      # TODO: Should not be gossiping optimistic blocks, but instead store them
      # in a cache and only gossip them after they are confirmed due to an LC
      # finalized header.
      notice "New LC optimistic block",
        opt = signedBlock.toBlockId(),
        wallSlot = getBeaconTime().slotOrZero

      withBlck(signedBlock):
        when stateFork >= BeaconStateFork.Bellatrix:
          if blck.message.is_execution_block:
            template payload(): auto = blck.message.body.execution_payload

            # TODO: Get rid of the asEngineExecutionPayload step
            let (hash, headerWithProof, body) =
              asPortalBlockData(payload.asEngineExecutionPayload())

            logScope:
              blockhash = history_content.`$`hash

            block: # gossip header
              let contentKey = ContentKey.init(blockHeader, hash)
              let encodedContentKey = contentKey.encode.asSeq()

              try:
                let peers = await rpcHttpclient.portal_historyGossip(
                  encodedContentKey.toHex(),
                  SSZ.encode(headerWithProof).toHex())
                info "Block header gossiped", peers,
                    contentKey = encodedContentKey.toHex()
              except CatchableError as e:
                error "JSON-RPC error", error = $e.msg

              await rpcHttpclient.close()

            # For bodies to get verified, the header needs to be available on
            # the network. Wait a little to get the headers propagated through
            # the network.
            await sleepAsync(1.seconds)

            block: # gossip block
              let contentKey = ContentKey.init(blockBody, hash)
              let encodedContentKey = contentKey.encode.asSeq()

              try:
                let peers = await rpcHttpclient.portal_historyGossip(
                  encodedContentKey.toHex(),
                  SSZ.encode(body).toHex())
                info "Block body gossiped", peers,
                    contentKey = encodedContentKey.toHex()
              except CatchableError as e:
                error "JSON-RPC error", error = $e.msg

            await rpcHttpclient.close()
      return

    optimisticProcessor = initOptimisticProcessor(
      getBeaconTime, optimisticHandler)

    lightClient = createLightClient(
      network, rng, lcConfig, cfg, forkDigests, getBeaconTime,
      genesis_validators_root, LightClientFinalizationMode.Optimistic)

  waitFor rpcHttpclient.connect(config.rpcAddress, Port(config.rpcPort), false)

  info "Listening to incoming network requests"
  network.initBeaconSync(cfg, forkDigests, genesisBlockRoot, getBeaconTime)
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.phase0),
    proc (signedBlock: phase0.SignedBeaconBlock): errors.ValidationResult =
      toValidationResult(
        optimisticProcessor.processSignedBeaconBlock(signedBlock)))
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.altair),
    proc (signedBlock: altair.SignedBeaconBlock): errors.ValidationResult =
      toValidationResult(
        optimisticProcessor.processSignedBeaconBlock(signedBlock)))
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.bellatrix),
    proc (signedBlock: bellatrix.SignedBeaconBlock): errors.ValidationResult =
      toValidationResult(
        optimisticProcessor.processSignedBeaconBlock(signedBlock)))
  lightClient.installMessageValidators()

  waitFor network.startListening()
  waitFor network.start()

  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: ForkedLightClientHeader) =
    withForkyHeader(finalizedHeader):
      when lcDataFork > LightClientDataFork.None:
        info "New LC finalized header",
          finalized_header = shortLog(forkyHeader)

  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: ForkedLightClientHeader) =
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.None:
        info "New LC optimistic header",
          optimistic_header = shortLog(forkyHeader)
        optimisticProcessor.setOptimisticHeader(forkyHeader.beacon)

  lightClient.onFinalizedHeader = onFinalizedHeader
  lightClient.onOptimisticHeader = onOptimisticHeader
  lightClient.trustedBlockRoot = some config.trustedBlockRoot

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
        cfg.CAPELLA_FORK_EPOCH, cfg.EIP4844_FORK_EPOCH, isBehind)

    template currentGossipState(): auto = blocksGossipState
    if currentGossipState == targetGossipState:
      return

    if currentGossipState.card == 0 and targetGossipState.card > 0:
      debug "Enabling blocks topic subscriptions",
        wallSlot = slot, targetGossipState
    elif currentGossipState.card > 0 and targetGossipState.card == 0:
      debug "Disabling blocks topic subscriptions",
        wallSlot = slot
    else:
      # Individual forks added / removed
      discard

    let
      newGossipForks = targetGossipState - currentGossipState
      oldGossipForks = currentGossipState - targetGossipState

    for gossipFork in oldGossipForks:
      let forkDigest = forkDigests[].atStateFork(gossipFork)
      network.unsubscribe(getBeaconBlocksTopic(forkDigest))

    for gossipFork in newGossipForks:
      let forkDigest = forkDigests[].atStateFork(gossipFork)
      network.subscribe(
        getBeaconBlocksTopic(forkDigest), blocksTopicParams,
        enableTopicMetrics = true)

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
  run()
