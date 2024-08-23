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
  ./constants,
  ./nimbus_desc,
  ./db/core_db/persistent,
  ./utils/era_helpers,
  kzg4844/kzg_ex as kzg,
  ./core/eip4844,
  web3, web3/[engine_api, primitives, conversions],
  beacon_chain/spec/digest,
  beacon_chain/el/el_conf,
  beacon_chain/el/el_manager,
  beacon_chain/spec/eth2_apis/[rest_types, rest_beacon_calls],
  beacon_chain/networking/network_metadata,
  eth/async_utils

var running {.volatile.} = true

# Load the EL block, from CL ( either head or CL root )
template getBlockFromBeaconChain(
    client: RestClientRef, blockIdent: BlockIdent, clConfig: RuntimeConfig
): (EthBlock, bool) =
  let clBlock =
    try:
      awaitWithTimeout(client.getBlockV2(blockIdent, clConfig), 30.seconds):
        error "Failed to get CL head"
        quit(QuitFailure)
    except CatchableError as exc:
      error "Error getting CL head", error = exc.msg
      quit(QuitFailure)

  # Constructing the EL block from the CL block
  var eth1block: EthBlock
  if clBlock.isSome():
    let data = clBlock.get()[]
    eth1Block = data.asTrusted().getEthBlock().valueOr:
        error "Failed to get EL block from CL head"
        quit(QuitFailure)
        
    (eth1Block, true)
  else:
    (eth1Block, false)

proc testApi(conf: NimbusConf) {.async.} =
  let jwtSecret = 
    if conf.jwtSecret.isSome():
      loadJwtSecret(Opt.some(conf.jwtSecret.get()))
    else:
      Opt.none(seq[byte])

  let engineUrl = EngineApiUrl.init(
    conf.beaconApi,
    jwtSecret
  )

  let web3 = await engineUrl.newWeb3()
  let rpcClient = web3.provider
  let data = await rpcClient.exchangeCapabilities(@["engine_exchangeTransitionConfigurationV1","engine_forkchoiceUpdatedV1","engine_getPayloadBodiesByHash","engine_getPayloadBodiesByRangeV1","engine_getPayloadV1","engine_newPayloadV1"])

  notice "Connected to Beacon Chain", data = data

proc loadBlocksFromBeaconChain(conf: NimbusConf) {.async.} =
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

  var
    currentBlockNumber = com.db.getSavedStateBlockNumber() + 1
    flags =
      boolFlag({PersistBlockFlag.NoValidation}, true) +
      boolFlag({PersistBlockFlag.NoFullValidation}, true) +
      boolFlag(NoPersistBodies, true) +
      boolFlag({PersistBlockFlag.NoPersistReceipts}, true)
    blocks: seq[EthBlock]
    curBlck: EthBlock
    lastEra1Block: uint64
    firstSlotAfterMerge: uint64
    clConfig: RuntimeConfig
    client = RestClientRef.new(conf.beaconApi).valueOr:
      error "Cannot connect to server"
      quit(QuitFailure)
    jwtSecret = 
      if conf.jwtSecret.isSome():
        loadJwtSecret(Opt.some(conf.jwtSecret.get()))
      else:
        Opt.none(seq[byte])

  if conf.networkId == MainNet:
    clConfig = getMetadataForNetwork("mainnet").cfg
    lastEra1Block = 15537393'u64 # Mainnet
    firstSlotAfterMerge = 4700013'u64
  elif conf.networkId == SepoliaNet:
    clConfig = getMetadataForNetwork("sepolia").cfg
    lastEra1Block = 1450408'u64 # Sepolia
    firstSlotAfterMerge = 115193'u64
  elif conf.networkId == HoleskyNet:
    clConfig = getMetadataForNetwork("holesky").cfg
    lastEra1Block = 0'u64
    firstSlotAfterMerge = 0'u64
  else:
    error "Unsupported network", network = conf.networkId
    quit(QuitFailure)

  template process() =
    let statusRes = chain.persistBlocks(blocks, flags)
    if statusRes.isErr():
      error "Failed to persist blocks", error = statusRes.error
      quit(QuitFailure)
    info "Persisted blocks", blocks = blocks.len
    blocks.setLen(0)

  template forwardSyncDb() =
      
    var (headBlck, _) = client.getBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Head), clConfig)

    if headBlck.header.number <= currentBlockNumber:
      notice "CL head is behind of EL head, or in sync", head = headBlck.header.number
      quit(QuitSuccess)

    var importedSlot = (currentBlockNumber - lastEra1Block) + firstSlotAfterMerge
    notice "Finding slot number corresponding to block", importedSlot

    var clNum = 0'u64
    while running and clNum < currentBlockNumber:
      let (blk, stat) = client.getBlockFromBeaconChain(
        BlockIdent.init(Slot(importedSlot)), clConfig
      )
      if not stat:
        importedSlot += 1
        continue

      clNum = blk.header.number
      # decreasing the lower bound with each iteration
      importedSlot += currentBlockNumber - clNum

    notice "Found the slot to start with", slot = importedSlot

    while running and currentBlockNumber < headBlck.header.number:
      var isAvailable = false
      (curBlck, isAvailable) = client.getBlockFromBeaconChain(
        BlockIdent.init(Slot(importedSlot)), clConfig
      )
      if not isAvailable:
        importedSlot += 1
        continue

      blocks.add(curBlck)
      importedSlot += 1
      currentBlockNumber = curBlck.header.number

      if blocks.lenu64 mod 1000 == 0 or currentBlockNumber == headBlck.header.number:
        notice "Blocks Downloaded from CL", numberOfBlocks = blocks.len
        process()
        currentBlockNumber = com.db.getSavedStateBlockNumber()
        (headBlck, _) = client.getBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Head), clConfig)

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

  waitFor testApi(conf)
