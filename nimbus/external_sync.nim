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
  beacon_chain/spec/eth2_apis/[rest_types, rest_beacon_calls],
  beacon_chain/networking/network_metadata,
  eth/async_utils

var running {.volatile.} = true

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

  let
    currentBlockNumber = com.db.getSavedStateBlockNumber()
    chain = com.newChain()
    clConfig = getMetadataForNetwork("sepolia").cfg

  var 
    client = RestClientRef.new("http://192.168.29.44:3000").valueOr:
      error "Cannot connect to server"
      quit(QuitFailure)
  
  let  
    clHead = 
      try:
        awaitWithTimeout(
            client.getBlockV2(BlockIdent.init(BlockIdentType.Head), clConfig), 
            30.seconds):
          error "Failed to get CL head"
          quit(QuitFailure)
      except CatchableError as exc:
        error "Error getting CL head", error = exc.msg
        quit(QuitFailure)

  if clHead.isSome():
    let data = clHead.get()[]
    let blck = data.asTrusted()
    notice "CL head is available", data

    let elBlock =
      blck.getEthBlock().valueOr:
        error "Failed to get Eth block"
        quit(QuitFailure)

    notice "Eth block", elBlock



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
  waitFor loadBlocksFromBeaconChain(conf)