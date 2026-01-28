# nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

import ../execution_chain/compile_info

import web3/primitives, chronos

proc workaround*(): int {.exportc.} =
  # TODO https://github.com/nim-lang/Nim/issues/24844
  return int(Future[Quantity]().internalValue)

import
  std/[os, net, options, strformat, terminal, typetraits],
  stew/io2,
  chronos/threadsync,
  chronicles,
  metrics,
  metrics/chronos_httpserver,
  nimcrypto/sysrand,
  eth/enr/enr,
  eth/net/nat,
  eth/p2p/discoveryv5/random2,
  beacon_chain/spec/[engine_authentication],
  beacon_chain/validators/keystore_management,
  beacon_chain/[
    buildinfo,
    conf as bnconf,
    beacon_node,
    nimbus_beacon_node,
    nimbus_binary_common,
    process_state,
  ],
  ./rpc/jwt_auth,
  ./[
    constants,
    conf as ecconf,
    el_sync,
    nimbus_desc,
    nimbus_execution_client,
    version_info,
  ]

const
  copyright = "Copyright (c) " & compileYear & " Status Research & Development GmbH"

type NStartUpCmd* {.pure.} = enum
  nimbus = "Run Ethereum node"
  beaconNode = "Run beacon node in stand-alone mode"
  executionClient = "Run execution client in stand-alone mode"

proc matchSymbolName*(T: type enum, p: string): T {.raises: [ValueError].} =
  let p = normalize(p)
  for e in T:
    if e.symbolName.normalize() == p:
      return e

  raise (ref ValueError)(msg: p & " does not match")

#!fmt: off
type
  # Some of these parameters are here for their --help value only - a second
  # parsing will happen within each thread assigning them to their actual end
  # targets
  NimbusConf = object
    configFile* {.
      desc: "Loads the configuration from a TOML file"
      name: "config-file" .}: Option[InputFile]

    network* {.
      desc: "Name of Ethereum network to join (mainnet, hoodi, sepolia, custom/folder)"
      defaultValueDesc: "mainnet"
      name: "network" .}: Option[string]

    dataDirFlag* {.
      desc: "The directory where nimbus will store all blockchain data"
      abbr: "d"
      name: "data-dir" .}: Option[OutDir]

    logLevel* {.
      desc: "Sets the log level for process and topics (e.g. \"DEBUG; TRACE:discv5,libp2p; REQUIRED:none; DISABLED:none\")"
      defaultValue: "INFO"
      name: "log-level" .}: string

    logFormat* {.
      desc: "Choice of log format (auto, colors, nocolors, json)"
      defaultValueDesc: "auto"
      defaultValue: StdoutLogKind.Auto
      name: "log-format" .}: StdoutLogKind

    metrics* {.flatten.}: MetricsConf

    numThreads* {.
      defaultValue: 0,
      desc: "Number of worker threads (\"0\" = use as many threads as there are CPU cores available)"
      name: "num-threads" .}: int

    # TODO beacon and execution engine must run on different ports - in order
    #      to keep compatibility with `--tcp-port` that is used in both, use
    #      consecutive ports unless specific ports are set - to be evaluated
    executionTcpPort* {.
      desc: "Listening TCP port for execution client network (devp2p)"
      name: "execution-tcp-port" .}: Option[Port]

    executionUdpPort* {.
      desc: "Listening UDP port for execution node discovery"
      name: "execution-udp-port" .}: Option[Port]

    beaconTcpPort* {.
      desc: "Listening TCP port for consensus client network (libp2p)"
      name: "beacon-tcp-port" .}: Option[Port]

    beaconUdpPort* {.
      desc: "Listening UDP port for beacon node discovery"
      name: "beacon-udp-port" .}: Option[Port]

    tcpPort* {.
      desc: "Listening TCP port for Ethereum traffic - tcp-port and tcp-port+1 will be used if set"
      name: "tcp-port" .}: Option[Port]

    udpPort* {.
      desc: "Listening UDP port for node discovery - udp-port and udp-port+1 will be used if set"
      name: "udp-port" .}: Option[Port]

    elSync* {.
      desc: "Turn on CL-driven sync of the EL, for syncing execution blocks from the consensus network"
      defaultValue: true
      name: "el-sync" .}: bool

    # detect if user added --engine-api option which is not valid in unified mode
    engineApiEnabled* {.
      hidden
      desc: "Enable the Engine API"
      defaultValue: false
      name: "engine-api" .}: bool

    trustedSetupFile* {.
      hidden
      desc: "Alternative EIP-4844 trusted setup file"
      defaultValue: none(string)
      defaultValueDesc: "Baked in trusted setup"
      name: "debug-trusted-setup-file" .}: Option[string]

    case cmd* {.command, defaultValue: NStartUpCmd.nimbus.}: NStartUpCmd
    of nimbus:
      discard
    of beaconNode:
      discard
    of executionClient:
      discard

#!fmt: on

type
  BeaconThreadConfig = object
    tsp: ThreadSignalPtr
    tcpPort: Port
    udpPort: Port
    elSync: bool

  ExecutionThreadConfig = object
    tsp: ThreadSignalPtr
    tcpPort: Port
    udpPort: Option[Port]

var jwtKey: JwtSharedKey

proc dataDir*(config: NimbusConf): string =
  string config.dataDirFlag.get(
    OutDir defaultDataDir("", config.network.loadEth2Network().cfg.name)
  )

proc justWait(tsp: ThreadSignalPtr) {.async: (raises: [CancelledError]).} =
  try:
    await tsp.wait()
  except AsyncError as exc:
    notice "Waiting failed", err = exc.msg

proc elSyncLoop(
    dag: ChainDAGRef, url: EngineApiUrl
) {.async: (raises: [CancelledError]).} =
  while true:
    await sleepAsync(12.seconds)

    # TODO trigger only when the EL needs syncing
    try:
      await syncToEngineApi(dag, url)
    except CatchableError as exc:
      # This can happen when the EL is busy doing some work, specially on
      # startup
      debug "Execution client not ready", err = exc.msg

proc runBeaconNode(p: BeaconThreadConfig) {.thread.} =
  var config = BeaconNodeConf.loadWithBanners(clientId, copyright, [specBanner], true).valueOr:
    stderr.writeLine error # Logging not yet set up
    quit QuitFailure

  let engineUrl =
    EngineApiUrl.init(&"http://127.0.0.1:{defaultEngineApiPort}/", Opt.some(jwtKey))

  config.metrics.enabled = false
  config.elUrls.add EngineApiUrlConfigValue(
    url: engineUrl.url, jwtSecret: some toHex(distinctBase(jwtKey))
  )

  config.statusBarEnabled = false # Multi-threading issues due to logging
  config.tcpPort = p.tcpPort
  config.udpPort = p.udpPort

  config.rpcEnabled.reset() # --rpc is meant for the EL

  info "Launching beacon node",
    version = fullVersionStr,
    bls_backend = $BLS_BACKEND,
    const_preset,
    cmdParams = commandLineParams(),
    config

  let
    # TODO https://github.com/status-im/nim-taskpools/issues/6
    #      share taskpool between bn and ec
    taskpool = setupTaskpool(config.numThreads)
    stopper = p.tsp.justWait()
    rng = HmacDrbgContext.new()
    node = (waitFor BeaconNode.init(rng, config, taskpool)).valueOr:
      waitFor p.tsp.fire() # Stop the other thread as well..
      return

  if stopper.finished():
    return

  if p.elSync:
    discard elSyncLoop(node.dag, engineUrl)

  dynamicLogScope(comp = "bn"):
    if node.nickname != "":
      dynamicLogScope(node = node.nickname):
        node.run(stopper)
    else:
      node.run(stopper)

  # Stop the other thread as well, in case we're stopping early
  waitFor p.tsp.fire()

proc runExecutionClient(p: ExecutionThreadConfig) {.thread.} =
  var config = makeConfig(ignoreUnknown = true)
  config.metrics.enabled = false
  config.engineApiEnabled = true
  config.engineApiPort = Port(defaultEngineApiPort)
  config.engineApiAddress = defaultAdminListenAddress
  config.jwtSecret.reset()
  config.jwtSecretValue = some toHex(distinctBase(jwtKey))
  config.agentString = "nimbus"
  config.tcpPort = p.tcpPort
  config.udpPortFlag = p.udpPort

  info "Launching execution client", version = FullVersionStr, config

  when compileOption("threads"):
    let
      # TODO https://github.com/status-im/nim-taskpools/issues/6
      #      share taskpool between bn and ec
      taskpool = setupTaskpool(int config.numThreads)
      com = setupCommonRef(config)
    com.taskpool = taskpool
  else:
    let com = setupCommonRef(config)

  dynamicLogScope(comp = "ec"):
    nimbus_execution_client.runExeClient(config, com, p.tsp.justWait())

  # Stop the other thread as well, in case `runExeClient` stopped early
  waitFor p.tsp.fire()

proc runCombinedClient() =
  # Make it harder to connect to the (internal) engine - this will of course
  # go away
  discard randomBytes(distinctBase(jwtKey))

  const banner = "Nimbus v0.0.1\p\pSubcommand options can also be used with the main node, see `beaconNode --help` and `executionClient --help`"

  var config = NimbusConf.loadWithBanners(
    banner, copyright, [specBanner], ignoreUnknown = true, setupLogger = true
  ).valueOr:
    writePanicLine error # Logging not yet set up
    quit QuitFailure

  setupFileLimits()

  ProcessState.setupStopHandlers()

  if not checkAndCreateDataDir(config.dataDir):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  let metricsServer = (waitFor initMetricsServer(config.metrics)).valueOr:
    quit 1

  # Nim GC metrics (for the main thread) will be collected in onSecond(), but
  # we disable piggy-backing on other metrics here.
  setSystemMetricsAutomaticUpdate(false)

  if config.engineApiEnabled:
    warn "Engine API is not available when running internal beacon node"

  # Trusted setup is shared between threads, so it needs to be initalized
  # from the main thread before anything else runs
  if config.trustedSetupFile.isSome:
    kzg.loadTrustedSetup(config.trustedSetupFile.get(), 0).isOkOr:
      fatal "Cannot load Kzg trusted setup from file", msg = error
      quit(QuitFailure)
  else:
    # Load eagerly to avoid race conditions - lazy kzg loading is not thread safe
    loadTrustedSetupFromString(kzg.trustedSetup, 0).expect(
      "Baked-in KZG setup is correct"
    )

  var bnThread: Thread[BeaconThreadConfig]
  let bnStop = ThreadSignalPtr.new().expect("working ThreadSignalPtr")
  createThread(
    bnThread,
    runBeaconNode,
    BeaconThreadConfig(
      tsp: bnStop,
      tcpPort: config.beaconTcpPort.get(config.tcpPort.get(Port defaultEth2TcpPort)),
      udpPort: config.beaconUdpPort.get(config.udpPort.get(Port defaultEth2TcpPort)),
      elSync: config.elSync,
    ),
  )

  var ecThread: Thread[ExecutionThreadConfig]
  let ecStop = ThreadSignalPtr.new().expect("working ThreadSignalPtr")
  createThread(
    ecThread,
    runExecutionClient,
    ExecutionThreadConfig(
      tsp: ecStop,
      tcpPort:
        # -1/+1 to make sure global default is respected but +1 is applied to --tcp-port
        config.executionTcpPort.get(
          Port(uint16(config.tcpPort.get(Port(defaultExecutionPort - 1))) + 1)
        ),
      udpPort:
        if config.executionUdpPort.isSome:
          config.executionUdpPort
        elif config.udpPort.isSome:
          some(Port(uint16(config.udpPort.get()) + 1))
        else:
          none(Port),
    ),
  )

  while not ProcessState.stopIt(notice("Shutting down", reason = it)):
    os.sleep(100)

  waitFor bnStop.fire()
  waitFor ecStop.fire()

  joinThread(bnThread)
  joinThread(ecThread)

  waitFor metricsServer.stopMetricsServer()

# noinline to keep it in stack traces
proc main() {.noinline, raises: [CatchableError].} =
  var
    params = commandLineParams()
    isEC = false
    isBN = false
  for i in 0 ..< params.len:
    try:
      discard NimbusCmd.matchSymbolName(params[i])
      isEC = true
      break
    except ValueError:
      discard
    try:
      discard BNStartUpCmd.matchSymbolName(params[i])
      isBN = true
      break
    except ValueError:
      discard

    try:
      case NStartUpCmd.matchSymbolName(params[i])
      of NStartUpCmd.beaconNode:
        isBN = true
        break
      of NStartUpCmd.executionClient:
        isEC = true
        break
      else:
        discard
    except ValueError:
      discard

  if isBN:
    nimbus_beacon_node.main()
  elif isEC:
    nimbus_execution_client.main()
  else:
    runCombinedClient()

when isMainModule:
  main()
