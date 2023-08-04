# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#
# This beacon_lc_bridge allows for following the head of the beacon chain and
# seeding the latest execution block headers and bodies into the Portal network.
#
# The bridge does consensus light client sync and follows beacon block gossip.
# Once it is synced, the execution payload of new beacon blocks will be
# extracted and injected in the Portal network as execution headers and blocks.
#
# The injection into the Portal network is done via the `portal_historyGossip`
# JSON-RPC endpoint of a running Fluffy node.
#
# If a web3 provider is configured, then block receipts will also be injected
# into the network whenever there is a new block. The web3 provider is needed
# to request the receipts. The receipts root is verified against the root
# provided bij the exection payload of the beacon block.
# To get the block receipts, the web3 provider currently needs to support the
# `eth_getBlockReceipts` JSON-RPC endpoint (not in standard specification).
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

{.push raises: [].}

import
  std/[os, strutils, options],
  chronicles, chronos, confutils,
  eth/[keys, rlp], eth/[trie, trie/db],
  # Need to rename this because of web3 ethtypes and ambigious indentifier mess
  # for `BlockHeader`.
  eth/common/eth_types as etypes,
  eth/common/eth_types_rlp,
  beacon_chain/el/el_manager,
  beacon_chain/gossip_processing/optimistic_processor,
  beacon_chain/networking/topic_params,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/[light_client, nimbus_binary_common],
  # Weirdness. Need to import this to be able to do errors.ValidationResult as
  # else we get an ambiguous identifier, ValidationResult from eth & libp2p.
  libp2p/protocols/pubsub/errors,
  ../../../nimbus/rpc/rpc_types,
  ../../rpc/[portal_rpc_client, eth_rpc_client],
  ../../network/history/[history_content, history_network],
  ../../network/beacon_light_client/beacon_light_client_content,
  ../../common/common_types,
  ./beacon_lc_bridge_conf

from stew/objects import checkedEnumAssign
from stew/byteutils import readHexChar
from web3/ethtypes import BlockHash

from beacon_chain/gossip_processing/block_processor import newExecutionPayload
from beacon_chain/gossip_processing/eth2_processor import toValidationResult

type Hash256 = etypes.Hash256

template asEthHash(hash: ethtypes.BlockHash): Hash256 =
  Hash256(data: distinctBase(hash))

# TODO: Ugh why isn't gasLimit and gasUsed a uint64 in nim-eth / nimbus-eth1 :(
template unsafeQuantityToInt64(q: Quantity): int64 =
  int64 q

# TODO: Cannot use the `hexToInt` from rpc_utils as it importing that causes a
# strange "Exception can raise an unlisted exception: Exception` compile error.
func hexToInt(
    s: string, T: typedesc[SomeInteger]): T {.raises: [ValueError].} =
  var i = 0
  if s[i] == '0' and (s[i+1] in {'x', 'X'}):
    inc(i, 2)
  if s.len - i > sizeof(T) * 2:
    raise newException(ValueError, "Input hex too big for destination int")

  var res: T = 0
  while i < s.len:
    res = res shl 4 or readHexChar(s[i]).T
    inc(i)

  res

func asTxType(quantity: HexQuantityStr): Result[TxType, string] =
  let value =
    try:
      hexToInt(quantity.string, uint8)
    except ValueError as e:
      return err("Invalid data for TxType: " & e.msg)

  var txType: TxType
  if not checkedEnumAssign(txType, value):
    err("Invalid data for TxType: " & $value)
  else:
    ok(txType)

func asReceipt(
    receiptObject: rpc_types.ReceiptObject): Result[Receipt, string] =
  let receiptType = asTxType(receiptObject.`type`).valueOr:
    return err("Failed conversion to TxType" & error)

  var logs: seq[Log]
  if receiptObject.logs.len > 0:
    for log in receiptObject.logs:
      var topics: seq[Topic]
      for topic in log.topics:
        topics.add(Topic(topic.data))

      logs.add(Log(
        address: log.address,
        data: log.data,
        topics: topics
      ))

  let cumulativeGasUsed =
    try:
      hexToInt(receiptObject.cumulativeGasUsed.string, GasInt)
    except ValueError as e:
      return err("Invalid data for cumulativeGasUsed: " & e.msg)

  if receiptObject.status.isSome():
    let status =
      try:
        hexToInt(receiptObject.status.get().string, int)
      except ValueError as e:
        return err("Invalid data for status: " & e.msg)
    ok(Receipt(
      receiptType: receiptType,
      isHash: false,
      status: status == 1,
      cumulativeGasUsed: cumulativeGasUsed,
      bloom: BloomFilter(receiptObject.logsBloom),
      logs: logs
    ))
  elif receiptObject.root.isSome():
    ok(Receipt(
      receiptType: receiptType,
      isHash: true,
      hash: receiptObject.root.get(),
      cumulativeGasUsed: cumulativeGasUsed,
      bloom: BloomFilter(receiptObject.logsBloom),
      logs: logs
    ))
  else:
    err("No root nor status field in the JSON receipt object")

proc calculateTransactionData(
    items: openArray[TypedTransaction]):
    Hash256 {.raises: [].} =

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

# TODO: Since Capella we can also access ExecutionPayloadHeader and thus
# could get the Roots through there instead.
proc calculateWithdrawalsRoot(
  items: openArray[WithdrawalV1]):
    Hash256 {.raises: [].} =

  var tr = initHexaryTrie(newMemoryDB())
  for i, w in items:
    try:
      let withdrawal = etypes.Withdrawal(
        index: distinctBase(w.index),
        validatorIndex: distinctBase(w.validatorIndex),
        address: distinctBase(w.address),
        amount: distinctBase(w.amount)
      )
      tr.put(rlp.encode(i), rlp.encode(withdrawal))
    except RlpError as e:
      raiseAssert(e.msg)

  return tr.rootHash()

proc asPortalBlockData*(
    payload: ExecutionPayloadV1):
    (common_types.BlockHash, BlockHeaderWithProof, PortalBlockBodyLegacy) =
  let
    txRoot = calculateTransactionData(payload.transactions)
    withdrawalsRoot = options.none(Hash256)

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
      withdrawalsRoot: withdrawalsRoot,
      blobGasUsed: options.none(uint64),
      excessBlobGas: options.none(uint64)
    )

    headerWithProof = BlockHeaderWithProof(
      header: ByteList(rlp.encode(header)),
      proof: BlockHeaderProof.init())

  var transactions: Transactions
  for tx in payload.transactions:
    discard transactions.add(TransactionByteList(distinctBase(tx)))

  let body = PortalBlockBodyLegacy(
    transactions: transactions,
    uncles: Uncles(@[byte 0xc0]))

  let hash = common_types.BlockHash(data: distinctBase(payload.blockHash))

  (hash, headerWithProof, body)

proc asPortalBlockData*(
    payload: ExecutionPayloadV2 | ExecutionPayloadV3):
    (common_types.BlockHash, BlockHeaderWithProof, PortalBlockBodyShanghai) =
  let
    txRoot = calculateTransactionData(payload.transactions)
    withdrawalsRoot = some(calculateWithdrawalsRoot(payload.withdrawals))

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
      withdrawalsRoot: withdrawalsRoot,
      blobGasUsed: options.none(uint64),
      excessBlobGas: options.none(uint64) # TODO: adjust later according to deneb fork
    )

    headerWithProof = BlockHeaderWithProof(
      header: ByteList(rlp.encode(header)),
      proof: BlockHeaderProof.init())

  var transactions: Transactions
  for tx in payload.transactions:
    discard transactions.add(TransactionByteList(distinctBase(tx)))

  func toWithdrawal(x: WithdrawalV1): Withdrawal =
    Withdrawal(
      index: x.index.uint64,
      validatorIndex: x.validatorIndex.uint64,
      address: x.address.EthAddress,
      amount: x.amount.uint64
    )

  var withdrawals: Withdrawals
  for w in payload.withdrawals:
    discard withdrawals.add(WithdrawalByteList(rlp.encode(toWithdrawal(w))))

  let body = PortalBlockBodyShanghai(
    transactions: transactions,
    uncles: Uncles(@[byte 0xc0]),
    withdrawals: withdrawals
    )

  let hash = common_types.BlockHash(data: distinctBase(payload.blockHash))

  (hash, headerWithProof, body)

func forkDigestAtEpoch(
    forkDigests: ForkDigests, epoch: Epoch, cfg: RuntimeConfig): ForkDigest =
  forkDigests.atEpoch(epoch, cfg)

proc getBlockReceipts(
    client: RpcClient, transactions: seq[TypedTransaction], blockHash: Hash256):
    Future[Result[seq[Receipt], string]] {.async.} =
  ## Note: This makes use of `eth_getBlockReceipts` JSON-RPC endpoint which is
  ## only supported by Alchemy.
  var receipts: seq[Receipt]
  if transactions.len() > 0:
    let receiptObjects =
      # TODO: Add some retries depending on the failure
      try:
        await client.eth_getBlockReceipts(blockHash)
      except CatchableError as e:
        await client.close()
        return err("JSON-RPC eth_getBlockReceipts failed: " & e.msg)

    await client.close()

    for receiptObject in receiptObjects:
      let receipt = asReceipt(receiptObject).valueOr:
        return err(error)
      receipts.add(receipt)

  return ok(receipts)

# TODO: This requires a seperate call for each transactions, which in reality
# takes too long and causes too much overhead. To make this usable the JSON-RPC
# code needs to get support for batch requests.
proc getBlockReceipts(
    client: RpcClient, transactions: seq[TypedTransaction]):
    Future[Result[seq[Receipt], string]] {.async.} =
  var receipts: seq[Receipt]
  for tx in transactions:
    let txHash = keccakHash(tx.distinctBase)
    let receiptObjectOpt =
      # TODO: Add some retries depending on the failure
      try:
        await client.eth_getTransactionReceipt(txHash)
      except CatchableError as e:
        await client.close()
        return err("JSON-RPC eth_getTransactionReceipt failed: " & e.msg)

    await client.close()

    if receiptObjectOpt.isNone():
      return err("eth_getTransactionReceipt returned no receipt")

    let receipt = asReceipt(receiptObjectOpt.get()).valueOr:
      return err(error)
    receipts.add(receipt)

  return ok(receipts)

proc run(config: BeaconBridgeConf) {.raises: [CatchableError].} =
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
          cfg, genesisData.toOpenArray(genesisData.low, genesisData.high)))
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

    portalRpcClient = newRpcHttpClient()

    web3Client: Opt[RpcClient] =
      if config.web3Url.isNone():
        Opt.none(RpcClient)
      else:
        let client: RpcClient =
          case config.web3Url.get().kind
          of HttpUrl:
            newRpcHttpClient()
          of WsUrl:
            newRpcWebSocketClient()
        Opt.some(client)

    optimisticHandler = proc(signedBlock: ForkedMsgTrustedSignedBeaconBlock):
        Future[void] {.async.} =
      # TODO: Should not be gossiping optimistic blocks, but instead store them
      # in a cache and only gossip them after they are confirmed due to an LC
      # finalized header.
      notice "New LC optimistic block",
        opt = signedBlock.toBlockId(),
        wallSlot = getBeaconTime().slotOrZero

      withBlck(signedBlock):
        when consensusFork >= ConsensusFork.Bellatrix:
          if blck.message.is_execution_block:
            template payload(): auto = blck.message.body.execution_payload

            # TODO: Get rid of the asEngineExecutionPayload step?
            let executionPayload = payload.asEngineExecutionPayload()
            let (hash, headerWithProof, body) =
              asPortalBlockData(executionPayload)

            logScope:
              blockhash = history_content.`$`hash

            block: # gossip header
              let contentKey = history_content.ContentKey.init(blockHeader, hash)
              let encodedContentKey = contentKey.encode.asSeq()

              try:
                let peers = await portalRpcClient.portal_historyGossip(
                  toHex(encodedContentKey),
                  SSZ.encode(headerWithProof).toHex())
                info "Block header gossiped", peers,
                    contentKey = encodedContentKey.toHex()
              except CatchableError as e:
                error "JSON-RPC error", error = $e.msg

              await portalRpcClient.close()

            # For bodies to get verified, the header needs to be available on
            # the network. Wait a little to get the headers propagated through
            # the network.
            await sleepAsync(2.seconds)

            block: # gossip block
              let contentKey = history_content.ContentKey.init(blockBody, hash)
              let encodedContentKey = contentKey.encode.asSeq()

              try:
                let peers = await portalRpcClient.portal_historyGossip(
                  encodedContentKey.toHex(),
                  SSZ.encode(body).toHex())
                info "Block body gossiped", peers,
                    contentKey = encodedContentKey.toHex()
              except CatchableError as e:
                error "JSON-RPC error", error = $e.msg

            await portalRpcClient.close()

            if web3Client.isSome():
              # get receipts
              let receipts =
                (await web3Client.get().getBlockReceipts(
                    executionPayload.transactions, hash)).valueOr:
                # (await web3Client.get().getBlockReceipts(
                #     executionPayload.transactions)).valueOr:
                  error "Error getting block receipts", error
                  return

              let portalReceipts = PortalReceipts.fromReceipts(receipts)
              if validateReceipts(portalReceipts, payload.receiptsRoot).isErr():
                error "Receipts root is invalid"
                return

              # gossip receipts
              let contentKey = history_content.ContentKey.init(
                history_content.ContentType.receipts, hash)
              let encodedContentKeyHex = contentKey.encode.asSeq().toHex()

              try:
                let peers = await portalRpcClient.portal_historyGossip(
                  encodedContentKeyHex,
                  SSZ.encode(portalReceipts).toHex())
                info "Block receipts gossiped", peers,
                    contentKey = encodedContentKeyHex
              except CatchableError as e:
                error "JSON-RPC error for portal_historyGossip", error = $e.msg

              await portalRpcClient.close()

      return

    optimisticProcessor = initOptimisticProcessor(
      getBeaconTime, optimisticHandler)

    lightClient = createLightClient(
      network, rng, lcConfig, cfg, forkDigests, getBeaconTime,
      genesis_validators_root, LightClientFinalizationMode.Optimistic)

  ### Beacon Light Client content bridging specific callbacks
  proc onBootstrap(
      lightClient: LightClient,
      bootstrap: ForkedLightClientBootstrap) =
    withForkyObject(bootstrap):
      when lcDataFork > LightClientDataFork.None:
        info "New Beacon LC bootstrap",
          forkyObject, slot = forkyObject.header.beacon.slot

        let
          root = hash_tree_root(forkyObject.header)
          contentKey = encode(bootstrapContentKey(root))
          contentId = beacon_light_client_content.toContentId(contentKey)
          forkDigest = forkDigestAtEpoch(
            forkDigests[], epoch(forkyObject.header.beacon.slot), cfg)
          content = encodeBootstrapForked(
            forkDigest,
            bootstrap
          )

        proc GossipRpcAndClose() {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconLightClientGossip(
                contentKeyHex,
                content.toHex())
            info "Beacon LC bootstrap gossiped", peers,
                contentKey = contentKeyHex
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
          contentId = beacon_light_client_content.toContentId(contentKey)
          forkDigest = forkDigestAtEpoch(
            forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)
          content = encodeLightClientUpdatesForked(
            forkDigest,
            @[update]
          )

        proc GossipRpcAndClose() {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconLightClientGossip(
                contentKeyHex,
                content.toHex())
            info "Beacon LC bootstrap gossiped", peers,
                contentKey = contentKeyHex
          except CatchableError as e:
            error "JSON-RPC error", error = $e.msg

          await portalRpcClient.close()

        asyncSpawn(GossipRpcAndClose())

  proc onOptimisticUpdate(
      lightClient: LightClient,
      update: ForkedLightClientOptimisticUpdate) =
    withForkyObject(update):
      when lcDataFork > LightClientDataFork.None:
        info "New Beacon LC optimistic update",
          update, slot = forkyObject.attested_header.beacon.slot

        let
          slot = forkyObject.attested_header.beacon.slot
          contentKey = encode(optimisticUpdateContentKey(slot.uint64))
          contentId = beacon_light_client_content.toContentId(contentKey)
          forkDigest = forkDigestAtEpoch(
            forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)
          content = encodeOptimisticUpdateForked(
            forkDigest,
            update
          )

        proc GossipRpcAndClose() {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconLightClientGossip(
                contentKeyHex,
                content.toHex())
            info "Beacon LC bootstrap gossiped", peers,
                contentKey = contentKeyHex
          except CatchableError as e:
            error "JSON-RPC error", error = $e.msg

          await portalRpcClient.close()

        asyncSpawn(GossipRpcAndClose())

  proc onFinalityUpdate(
      lightClient: LightClient,
      update: ForkedLightClientFinalityUpdate) =
    withForkyObject(update):
      when lcDataFork > LightClientDataFork.None:
        info "New Beacon LC finality update",
          update, slot = forkyObject.attested_header.beacon.slot
        let
          finalizedSlot = forkyObject.finalized_header.beacon.slot
          optimisticSlot = forkyObject.attested_header.beacon.slot
          contentKey = encode(finalityUpdateContentKey(
            finalizedSlot.uint64, optimisticSlot.uint64))
          contentId = beacon_light_client_content.toContentId(contentKey)
          forkDigest = forkDigestAtEpoch(
            forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)
          content = encodeFinalityUpdateForked(
            forkDigest,
            update
          )

        proc GossipRpcAndClose() {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconLightClientGossip(
                contentKeyHex,
                content.toHex())
            info "Beacon LC bootstrap gossiped", peers,
                contentKey = contentKeyHex
          except CatchableError as e:
            error "JSON-RPC error", error = $e.msg

          await portalRpcClient.close()

        asyncSpawn(GossipRpcAndClose())

  ###

  waitFor portalRpcClient.connect(config.rpcAddress, Port(config.rpcPort), false)

  if web3Client.isSome():
    if config.web3Url.get().kind == HttpUrl:
      waitFor (RpcHttpClient(web3Client.get())).connect(config.web3Url.get().web3Url)

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
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.capella),
    proc (signedBlock: capella.SignedBeaconBlock): errors.ValidationResult =
      toValidationResult(
        optimisticProcessor.processSignedBeaconBlock(signedBlock)))
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.deneb),
    proc (signedBlock: deneb.SignedBeaconBlock): errors.ValidationResult =
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
        cfg.CAPELLA_FORK_EPOCH, cfg.DENEB_FORK_EPOCH, isBehind)

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
      let forkDigest = forkDigests[].atConsensusFork(gossipFork)
      network.unsubscribe(getBeaconBlocksTopic(forkDigest))

    for gossipFork in newGossipForks:
      let forkDigest = forkDigests[].atConsensusFork(gossipFork)
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
  {.pop.}
  var config = makeBannerAndConfig(
    "Nimbus beacon chain bridge", BeaconBridgeConf)
  {.push raises: [].}

  run(config)
