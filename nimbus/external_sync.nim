# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, strutils, net],
  chronicles,
  ./constants,
  ./nimbus_desc,
  ./db/core_db/persistent,
  ./utils/era_helpers,
  beacon_chain/spec/digest,
  beacon_chain/spec/eth2_apis/[rest_types, rest_beacon_calls],
  beacon_chain/networking/network_metadata,
  eth/async_utils

var running {.volatile.} = true

template getRootFromHeader(client: RestClientRef, blockIdent: BlockIdent): Eth2Digest =
  let
    clHeader =
      try:
        awaitWithTimeout(
            client.getBlockHeader(blockIdent), 
            30.seconds):
          error "Failed to get CL head"
          quit(QuitFailure)
      except CatchableError as exc:
        error "Error getting CL head", error = exc.msg
        quit(QuitFailure)

  if clHeader.isSome():
    let beaconHeader = clHeader.get()
    beaconHeader.data.header.message.parent_root

  else:
    error "CL header is not available"
    quit(QuitFailure)
  

template getBlockFromBeaconChain(client: RestClientRef, blockIdent: BlockIdent, clConfig: RuntimeConfig): (EthBlock, Eth2Digest) =
  let  
    clBlock = 
      try:
        awaitWithTimeout(
            client.getBlockV2(blockIdent, clConfig), 
            30.seconds):
          error "Failed to get CL head"
          quit(QuitFailure)
      except CatchableError as exc:
        error "Error getting CL head", error = exc.msg
        quit(QuitFailure)

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
  let coreDB =
    # Resolve statically for database type
    case conf.chainDbMode:
    of Aristo,AriPrune:
      AristoDbRocks.newCoreDbRef(string conf.dataDir, conf.dbOptions())

  let com = CommonRef.new(
    db = coreDB,
    pruneHistory = (conf.chainDbMode == AriPrune),
    networkId = conf.networkId,
    params = conf.networkParams)

  defer:
    com.db.finish()

  template boolFlag(flags, b): PersistBlockFlags =
    if b:
      flags
    else:
      {}

  let
    currentBlockNumber = com.db.getSavedStateBlockNumber()
    chain = com.newChain()
    clConfig = getMetadataForNetwork("sepolia").cfg

  var
    # flags =
    #   boolFlag({PersistBlockFlag.NoValidation}, conf.noValidation) +
    #   boolFlag({PersistBlockFlag.NoFullValidation}, not conf.fullValidation) +
    #   boolFlag(NoPersistBodies, not conf.storeBodies) +
    #   boolFlag({PersistBlockFlag.NoPersistReceipts}, not conf.storeReceipts)
    blocks: seq[EthBlock]
    hashChain: seq[Eth2Digest]
    curBlck: EthBlock
    prevHash: Eth2Digest
    client = RestClientRef.new("http://127.0.0.1:5052").valueOr:
      error "Cannot connect to server"
      quit(QuitFailure)
  
  (curBlck, prevHash) = client.getBlockFromBeaconChain(BlockIdent.init(BlockIdentType.Head), clConfig)
  hashChain.add(prevHash) # adding the head
  notice "Got block from CL head", prevhash

  # Difference Log
  notice "Current block number", currentBlockNumber
  let headNumber = curBlck.header.number
  notice "Block number from CL head", headNumber
  var diff = headNumber - currentBlockNumber
  notice "Number of blocks to be covered", diff

  # TODO: Check if CL head is behind the EL head

  let time1 = Moment.now()
  while running and diff > 0:
    prevHash = client.getRootFromHeader(BlockIdent.init(prevHash))
    hashChain.add(prevHash)
    diff = diff - 1
    let 
      time2 = Moment.now()
      diff1 = (time2 - time1).nanoseconds().float / 1000000000
      speed = hashChain.len.float / diff1
      remaining = diff.float / speed
    notice "Remaining blocks to be covered", diff
    notice "Speed of fetching blocks", speed
    notice "Time remaining", remaining

  let chainLen = hashChain.len
  notice "Blocks loaded from CL", chainLen

  while running and hashChain.len > 0:

    for i in 0 ..< 50:
      let (eth1blck, _) = client.getBlockFromBeaconChain(BlockIdent.init(hashChain.pop()), clConfig)
      blocks.add(eth1blck)

    let statusRes = chain.persistBlocks(blocks)
    if statusRes.isErr():
      error "Failed to persist blocks", error = statusRes.error
      quit(QuitFailure)
    info "Persisted blocks"
    blocks.setLen(0)

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
  waitFor loadBlocksFromBeaconChain(conf)