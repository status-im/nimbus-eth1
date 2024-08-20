# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronicles,
  ./constants,
  ./nimbus_desc,
  ./db/core_db/persistent,
  ./utils/era_helpers,
  kzg4844/kzg_ex as kzg,
  ./core/eip4844,
  beacon_chain/spec/digest,
  beacon_chain/spec/eth2_apis/[rest_types, rest_beacon_calls],
  beacon_chain/networking/network_metadata,
  eth/async_utils

var running {.volatile.} = true

# Load the parent root of CL block from the CL header
template getRootFromHeader(client: RestClientRef, blockIdent: BlockIdent): Eth2Digest =
  let clHeader =
    try:
      awaitWithTimeout(client.getBlockHeader(blockIdent), 30.seconds):
        error "Failed to get CL head"
        quit(QuitFailure)
    except CatchableError as exc:
      error "Error getting CL head", error = exc.msg
      quit(QuitFailure)

  # Fetching the parent root from the CL header
  if clHeader.isSome():
    let beaconHeader = clHeader.get()
    beaconHeader.data.header.message.parent_root
  else:
    error "CL header is not available"
    quit(QuitFailure)

# Load the EL block, from CL ( either head or CL root )
template getBlockFromBeaconChain(
    client: RestClientRef, blockIdent: BlockIdent, clConfig: RuntimeConfig
): (EthBlock, Eth2Digest) =
  let clBlock =
    try:
      awaitWithTimeout(client.getBlockV2(blockIdent, clConfig), 30.seconds):
        error "Failed to get CL head"
        quit(QuitFailure)
    except CatchableError as exc:
      error "Error getting CL head", error = exc.msg
      quit(QuitFailure)

  # Constructing the EL block from the CL block
  var prev_hash: Eth2Digest
  var eth1block: EthBlock
  if clBlock.isSome():
    let data = clBlock.get()[]
    eth1Block = data.asTrusted().getEthBlock().valueOr:
        error "Failed to get EL block from CL head"
        quit(QuitFailure)

    withBlck(data):
      prev_hash = forkyBlck.toBeaconBlockHeader().parent_root

    (eth1Block, prev_hash)
  else:
    error "CL head is not available"
    quit(QuitFailure)

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
    networkName =
      if conf.networkId == MainNet:
        "mainnet"
      elif conf.networkId == SepoliaNet:
        "sepolia"
      elif conf.networkId == HoleskyNet:
        "holesky"
      else:
        error "Unsupported network", network = conf.networkId
        quit(QuitFailure)
    clConfig = getMetadataForNetwork(networkName).cfg

  var
    currentBlockNumber = com.db.getSavedStateBlockNumber()
    flags =
      boolFlag({PersistBlockFlag.NoValidation}, true) +
      boolFlag({PersistBlockFlag.NoFullValidation}, true) +
      boolFlag(NoPersistBodies, true) +
      boolFlag({PersistBlockFlag.NoPersistReceipts}, true)
    blocks: seq[EthBlock]
    hashChain: seq[Eth2Digest]
    curBlck: EthBlock
    prevHash: Eth2Digest
    client = RestClientRef.new(conf.beaconApi).valueOr:
      error "Cannot connect to server"
      quit(QuitFailure)

  # Constructs a sequence of hashes from the head of chain to the current block
  template backTraceChainFromHead() =
    # Difference Log
    notice "Current block number", currentBlockNumber
    let head_number = curBlck.header.number
    notice "Block number from CL head", head_number = head_number
    var diff = head_number - currentBlockNumber
    notice "Number of blocks to be covered", diff = diff

    # Check if CL head is behind the EL head
    if currentBlockNumber > head_number:
      error "CL head is behind the EL head"
      quit(QuitFailure)

    if diff != 1:
      let time1 = Moment.now()
      while running and diff > 2:
        prevHash = client.getRootFromHeader(BlockIdent.init(prevHash))
        hashChain.add(prevHash)
        diff = diff - 1

        # Very crude approcimations, TODO: Improve
        let
          time2 = Moment.now()
          diff1 = (time2 - time1).nanoseconds().float / 1000000000
          speed = hashChain.len.float / diff1
          remaining = diff.float / speed
        notice "Remaining blocks to be covered", diff = diff
        notice "Speed of fetching blocks", speed = speed
        notice "Time remaining", remaining = remaining

      let (clBlck, _) = client.getBlockFromBeaconChain(
        BlockIdent.init(hashChain[hashChain.len - 1]), clConfig
      )
      notice "Blocks loaded from CL", chainLen = hashChain.len
      notice "Last block loaded from CL", blockNumber = clBlck.header.number
      notice "Current block number", currentBlockNumber

  # Download the blocks from CL and load into the EL
  template sync() =
    while running and hashChain.len > 0:
      if hashChain.len <= 1:
        blocks.add(curBlck)
        hashChain.setLen(0)
      else:
        let maxBlocks = 2000 # Load 2000 block at a time
        for i in 0 ..< (if hashChain.len <= maxBlocks: hashChain.len else: maxBlocks):
          let (eth1blck, _) =
            client.getBlockFromBeaconChain(BlockIdent.init(hashChain.pop()), clConfig)
          blocks.add(eth1blck)
        blocks.add(curBlck)

      notice "Blocks Downloaded from CL", numberOfBlocks = blocks.len

      let statusRes = chain.persistBlocks(blocks, flags)
      if statusRes.isErr():
        error "Failed to persist blocks", error = statusRes.error
        quit(QuitFailure)
      info "Persisted blocks"
      blocks.setLen(0)

  # First time loading of the head state
  (curBlck, prevHash) =
    client.getBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Head), clConfig)
  notice "Got block from CL head", prevhash

  # Keep construsting chain until the current block number is reached
  while running and currentBlockNumber < curBlck.header.number:
    hashChain.add(prevHash) # adding the head
    backTraceChainFromHead()
    sync()
    (curBlck, prevHash) =
      client.getBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Head), clConfig)
    currentBlockNumber = com.db.getSavedStateBlockNumber()

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

  waitFor loadBlocksFromBeaconChain(conf)
