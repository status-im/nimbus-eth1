# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/sequtils,
  chronicles,
  ../nimbus/constants,
  ../nimbus/core/chain,
  ./config,
  ../nimbus/db/core_db/persistent,
  ../nimbus/utils/era_helpers,
  kzg4844/kzg_ex as kzg,
  ../nimbus/core/eip4844,
  web3, web3/[engine_api, primitives, conversions],
  beacon_chain/spec/digest,
  beacon_chain/el/el_conf,
  beacon_chain/el/el_manager,
  beacon_chain/spec/[forks, state_transition_block],
  beacon_chain/spec/eth2_apis/[rest_types, rest_beacon_calls],
  beacon_chain/networking/network_metadata,
  eth/async_utils

var running* {.volatile.} = true

# Load the EL block, from CL ( either head or CL root )
template getCLBlockFromBeaconChain(
    client: RestClientRef, blockIdent: BlockIdent, clConfig: RuntimeConfig
): (ForkedSignedBeaconBlock, bool) =
  let clBlock =
    try:
      awaitWithTimeout(client.getBlockV2(blockIdent, clConfig), 30.seconds):
        error "Failed to get CL head"
        quit(QuitFailure)
    except CatchableError as exc:
      error "Error getting CL head", error = exc.msg
      quit(QuitFailure)

  # Constructing the EL block from the CL block
  var blck: ForkedSignedBeaconBlock
  if clBlock.isSome():
    let blck = clBlock.get()[]
        
    (blck, true)
  else:
    (blck, false)

# Load the EL block, from CL ( either head or CL root )
template getELBlockFromBeaconChain(
    client: RestClientRef, blockIdent: BlockIdent, clConfig: RuntimeConfig
): (EthBlock, bool) =
  let (clBlock, isAvailable) = getCLBlockFromBeaconChain(client, blockIdent, clConfig)

  # Constructing the EL block from the CL block
  var eth1block: EthBlock
  if isAvailable:
    eth1Block = clBlock.asTrusted().getEthBlock().valueOr:
        error "Failed to get EL block from CL head"
        quit(QuitFailure)
        
    (eth1Block, true)
  else:
    (eth1Block, false)

template loadNetworkConfig(conf: NRpcConf): (RuntimeConfig, uint64, uint64) =
  case conf.networkId
  of MainNet:
    (getMetadataForNetwork("mainnet").cfg, 15537393'u64, 4700013'u64)
  of SepoliaNet:
    (getMetadataForNetwork("sepolia").cfg, 1450408'u64, 115193'u64)
  of HoleskyNet:
    (getMetadataForNetwork("holesky").cfg, 0'u64, 0'u64)
  else:
    error "Unsupported network", network = conf.networkId
    quit(QuitFailure)

template findSlot(client: RestClientRef, currentBlockNumber: uint64, lastEra1Block: uint64, firstSlotAfterMerge: uint64): uint64 =
  var importedSlot = (currentBlockNumber - lastEra1Block) + firstSlotAfterMerge
  notice "Finding slot number corresponding to block", importedSlot

  var clNum = 0'u64
  while running and clNum < currentBlockNumber:
    let (blk, stat) = client.getELBlockFromBeaconChain(
      BlockIdent.init(Slot(importedSlot)), clConfig
    )
    if not stat:
      importedSlot += 1
      continue

    clNum = blk.header.number
    # decreasing the lower bound with each iteration
    importedSlot += currentBlockNumber - clNum

  notice "Found the slot to start with", slot = importedSlot
  importedSlot

proc syncToEngineApi*(conf: NRpcConf) {.async.} =

  template boolFlag(flags, b): PersistBlockFlags =
    if b:
      flags
    else:
      {}

  let
    (clConfig, lastEra1Block, firstSlotAfterMerge) = loadNetworkConfig(conf)
    jwtSecret = 
      if conf.jwtSecret.isSome():
        loadJwtSecret(Opt.some(conf.jwtSecret.get()))
      else:
        Opt.none(seq[byte])
    engineUrl = EngineApiUrl.init(
        conf.eth1EngineApi,
        jwtSecret
      )

    web3 = await engineUrl.newWeb3()
    rpcClient = web3.provider
    data = 
      try:
        await rpcClient.exchangeCapabilities(@["engine_exchangeTransitionConfigurationV1","engine_forkchoiceUpdatedV1","engine_getPayloadBodiesByHash","engine_getPayloadBodiesByRangeV1","engine_getPayloadV1","engine_newPayloadV1"])
      except CatchableError as exc:
        error "Error Connecting to the EL Engine API", error = exc.msg
        @[]

  notice "Connected to Beacon Chain", data = data

  template elBlockNumber(): uint64 =
    try:
      uint64(await rpcClient.eth_blockNumber())
    except CatchableError as exc:
      error "Error getting block number", error = exc.msg
      0'u64

  var
    currentBlockNumber = elBlockNumber()
    curBlck: ForkedSignedBeaconBlock
    client = RestClientRef.new(conf.beaconApi).valueOr:
      error "Cannot connect to server"
      quit(QuitFailure)

  notice "Current block number", number = currentBlockNumber
  var
    (finalizedBlck, _) = client.getELBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Finalized), clConfig)
    (headBlck, _) = client.getELBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Head), clConfig)

  if headBlck.header.number <= currentBlockNumber:
    notice "CL head is behind of EL head, or in sync", head = headBlck.header.number
    quit(QuitSuccess)

  var
    importedSlot = findSlot(client, currentBlockNumber, lastEra1Block, firstSlotAfterMerge)
    finalizedHash: Eth2Digest
    headHash: Eth2Digest

  while running and currentBlockNumber < headBlck.header.number:

    var isAvailable = false
    (curBlck, isAvailable) = client.getCLBlockFromBeaconChain(
      BlockIdent.init(Slot(importedSlot)), clConfig
    )
    importedSlot += 1
    if not isAvailable:
      importedSlot += 1
      continue

    withBlck(curBlck):
      when consensusFork >= ConsensusFork.Deneb:
        let
          payload = forkyBlck.message.body.execution_payload.asEngineExecutionPayload
          versioned_hashes = mapIt(
                  forkyBlck.message.body.blob_kzg_commitments,
                  engine_api.VersionedHash(kzg_commitment_to_versioned_hash(it)))
          data = await rpcClient.newPayload(
            payload, versioned_hashes, 
            FixedBytes[32] forkyBlck.message.parent_root.data)
        notice "Payload status", response = data

        headHash = forkyBlck.message.body.execution_payload.block_hash
        if currentBlockNumber == finalizedBlck.header.number:
          notice "Finalized block reached", number = currentBlockNumber
          finalizedHash = finalizedBlck.header.parentHash
          (finalizedBlck, _) = client.getELBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Finalized), clConfig)

    
    var
      state = ForkchoiceStateV1(
        headBlockHash: headHash.asBlockHash,
        safeBlockHash: finalizedHash.asBlockHash,
        finalizedBlockHash: finalizedHash.asBlockHash)
      fcudata = await rpcClient.forkchoiceUpdated(state, Opt.none(PayloadAttributesV3))
    notice "Forkchoice Updated", response = fcudata

    currentBlockNumber = elBlockNumber()
    (headBlck, _) = client.getELBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Head), clConfig)


proc syncToDatabase*(conf: NRpcConf) {.async.} =
  let coreDB = AristoDbRocks.newCoreDbRef(string conf.dataDir, conf.dbOptions())

  let com = CommonRef.new(
    db = coreDB,
    pruneHistory = (conf.chainDbMode == AriPrune),
    networkId = conf.networkId,
    params = conf.networkParams,
  )

  defer:
    com.db.finish()

  template boolFlag(flags, b): PersistBlockFlags =
    if b:
      flags
    else:
      {}

  let
    chain = com.newChain()
    (clConfig, lastEra1Block, firstSlotAfterMerge) = loadNetworkConfig(conf)

  var
    currentBlockNumber = com.db.getSavedStateBlockNumber() + 1
    flags =
      boolFlag({PersistBlockFlag.NoValidation}, conf.noValidation) +
      boolFlag({PersistBlockFlag.NoFullValidation}, not conf.fullValidation) +
      boolFlag(NoPersistBodies, not conf.storeBodies) +
      boolFlag({PersistBlockFlag.NoPersistReceipts}, not conf.storeReceipts) +
      boolFlag({PersistBlockFlag.NoPersistSlotHashes}, not conf.storeSlotHashes)
    blocks: seq[EthBlock]
    curBlck: EthBlock
    client = RestClientRef.new(conf.beaconApi).valueOr:
      error "Cannot connect to server"
      quit(QuitFailure)

  template process() =
    let statusRes = chain.persistBlocks(blocks, flags)
    if statusRes.isErr():
      error "Failed to persist blocks", error = statusRes.error
      quit(QuitFailure)
    info "Persisted blocks", blocks = blocks.len
    blocks.setLen(0)

  var (headBlck, _) = client.getELBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Finalized), clConfig)

  if headBlck.header.number <= currentBlockNumber:
    notice "CL head is behind of EL head, or in sync", head = headBlck.header.number
    quit(QuitSuccess)

  info "Current block number", number = currentBlockNumber
  info "Blocks till head", blocks = headBlck.header.number - currentBlockNumber

  var importedSlot = findSlot(client, currentBlockNumber, lastEra1Block, firstSlotAfterMerge)

  while running and currentBlockNumber < headBlck.header.number:
    var isAvailable = false
    (curBlck, isAvailable) = client.getELBlockFromBeaconChain(
      BlockIdent.init(Slot(importedSlot)), clConfig
    )
    if not isAvailable:
      importedSlot += 1
      continue

    blocks.add(curBlck)
    importedSlot += 1
    currentBlockNumber = curBlck.header.number

    if blocks.lenu64 mod conf.chunkSize == 0 or currentBlockNumber == headBlck.header.number:
      notice "Blocks Downloaded from CL", numberOfBlocks = blocks.len
      process()
      currentBlockNumber = com.db.getSavedStateBlockNumber()
      (headBlck, _) = client.getELBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Finalized), clConfig)

  if blocks.len > 0:
    process()

when isMainModule:
  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    running = false

  setControlCHook(controlCHandler)

  ## Show logs on stdout until we get the user's logging choice
  discard defaultChroniclesStream.output.open(stdout)

  ## Processing command line arguments
  let conf = makeConfig()
  setLogLevel(conf.logLevel)


  case conf.cmd
  of NRpcCmd.`sync_db`:
    # Trusted setup is needed for processing Cancun+ blocks
    if conf.trustedSetupFile.isSome:
      let fileName = conf.trustedSetupFile.get()
      let res = Kzg.loadTrustedSetup(fileName)
      if res.isErr:
        fatal "Cannot load Kzg trusted setup from file", msg = res.error
        quit(QuitFailure)
    else:
      let res = loadKzgTrustedSetup()
      if res.isErr:
        fatal "Cannot load baked in Kzg trusted setup", msg = res.error
        quit(QuitFailure)
    waitFor syncToDatabase(conf)
  else:
    waitFor syncToEngineApi(conf)
