# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[concurrency/atomics, os, exitprocs],
  chronicles,
  execution/execution_layer,
  consensus/consensus_layer,
  common/utils,
  conf,
  confutils/cli_parser,
  stew/io2

from beacon_chain/conf import BeaconNodeConf
from ../execution_chain/config import NimbusConf
from beacon_chain/nimbus_binary_common import setupFileLimits, shouldCreatePidFile

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

#beacon node db lock
var beaconNodeLock {.global.}: string

proc createBeaconNodeFileLock(filename: string) {.raises: [IOError].} =
  shouldCreatePidFile.store(false)

  writeFile filename, $os.getCurrentProcessId()
  beaconNodeLock = filename

  addExitProc proc() {.noconv.} =
    if beaconNodeLock.len > 0:
      discard io2.removeFile(beaconNodeLock)

## create and configure service
proc startService(nimbus: var Nimbus, service: var NimbusService) =
  var serviceChannel =
    cast[ptr Channel[pointer]](allocShared0(sizeof(Channel[pointer])))

  serviceChannel[].open()

  isConfigRead.store(false)

  try:
    createThread(service.serviceHandler, service.serviceFunc, serviceChannel)
  except Exception as e:
    fatal "error creating thread", err = e.msg

  let optionsTable = block:
    case service.layerConfig.kind
    of Consensus: service.layerConfig.consensusOptions
    of Execution: service.layerConfig.executionOptions

  #configs table total size
  var totalSize: uint = 0
  totalSize += uint(sizeof(uint))
  for opt, arg in optionsTable:
    totalSize += uint(sizeof(uint)) + uint(opt.len) # option
    totalSize += uint(sizeof(uint)) + uint(arg.len) # arg

  # Allocate shared memory
  # schema: (table size:Uint) | [ (option size:Uint) (option data:byte) (arg size: Uint) (arg data:byte)]
  var byteArray = cast[ptr byte](allocShared(totalSize))
  if byteArray.isNil:
    fatal "Memory allocation failed"
    quit QuitFailure

  var writeOffset = cast[uint](byteArray)
  copyMem(cast[pointer](writeOffset), addr totalSize, sizeof(uint))
  writeOffset += uint(sizeof(uint))

  for opt, arg in optionsTable:
    writeConfigString(writeOffset, opt)
    writeConfigString(writeOffset, arg)

  try:
    serviceChannel[].send(byteArray)
  except Exception as e:
    fatal "channel error: ", err = e.msg

  #wait for service read ack
  while not isConfigRead.load():
    sleep(cThreadTimeAck)
  isConfigRead.store(true)

  serviceChannel[].close()
  #dealloc shared data
  deallocShared(byteArray)
  deallocShared(serviceChannel)

## Gracefully exits all services
proc monitorServices(nimbus: Nimbus) =
  for service in nimbus.serviceList:
    joinThread(service.serviceHandler)
    info "Exited service ", service = service.name

  notice "Exited all services"

## Auxiliary function to prepare arguments and options for eth1 and eth2
func addArg(
    paramTable: var NimbusConfigTable, cmdKind: CmdLineKind, key: string, arg: string
) =
  var
    newKey = ""
    newArg = ""

  if cmdKind == cmdLongOption:
    newKey = "--" & key

  if cmdKind == cmdShortOption:
    newKey = "-" & key

  if arg != "":
    newArg = "=" & arg

  paramTable[newKey] = newArg

proc controlCHandler() {.noconv.} =
  when defined(windows):
    # workaround for https://github.com/nim-lang/Nim/issues/4057
    try:
      setupForeignThreadGc()
    except NimbusServiceError as exc:
      raiseAssert exc.msg # shouldn't happen

  notice "\tCtrl+C pressed. Shutting down services ..."

  shutdownExecution()
  shutdownConsensus()

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

# Setup nimbus and services
proc setup(nimbus: var Nimbus) {.raises: [CatchableError].} =
  let
    executionConfigNames = extractFieldNames(NimbusConf)
    consensusConfigNames = extractFieldNames(BeaconNodeConf)

  var consensusParams, executionParams = NimbusConfigTable()

  for cmdKind, cmdKey, cmdArg in getopt(commandLineParams()):
    var found = false
    if cmdKey in consensusConfigNames:
      consensusParams.addArg(cmdKind, cmdKey, cmdArg)
      found = true

    if cmdKey in executionConfigNames:
      executionParams.addArg(cmdKind, cmdKey, cmdArg)
      found = true

    if not found:
      error "Unrecognized option ", option = cmdKey
      #TODO: invoke configurations helpers
      quit 0

  let
    consensusService = NimbusService(
      name: "Consensus Layer",
      serviceFunc: consensusLayerHandler,
      layerConfig: LayerConfig(kind: Consensus, consensusOptions: consensusParams),
    )
    executionService = NimbusService(
      name: "Execution Layer",
      serviceFunc: executionLayerHandler,
      layerConfig: LayerConfig(kind: Execution, executionOptions: executionParams),
    )

  nimbus.serviceList.add(executionService)
  nimbus.serviceList.add(consensusService)

  # todo: replace path with config,datadir when creating Nimbus config
  createBeaconNodeFileLock(".beacon_node.pid")

## start nimbus client
proc run*(nimbus: var Nimbus) =
  try:
    for service in nimbus.serviceList.mitems():
      info "Starting service ", service = service.name
      nimbus.startService(service)
  except Exception as e:
    fatal "error starting service:", msg = e.msg
    quit QuitFailure

  # handling Ctrl+C signal
  # note: do not move. Both execution and consensus clients create these handlers.
  setControlCHook(controlCHandler)

  # wait for shutdown
  nimbus.monitorServices()

{.pop.}
# -----

when isMainModule:
  notice "Starting Nimbus"

  setupFileLimits()

  # todo: replace path with config after creating Nimbus config
  # setupLogging(config.logLevel, config.logStdout, config.logFile)

  var nimbus = Nimbus()
  nimbus.setup()
  nimbus.run()

# -----
when defined(testing):
  export monitorServices, startService
