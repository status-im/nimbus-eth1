# nimbus
# Copyright (c) 2025 Status Research & Development GmbH
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
  std/[os, net, options, typetraits],
  chronos/threadsync,
  chronicles,
  metrics,
  nimcrypto/sysrand,
  eth/net/nat,
  ./constants,
  ./nimbus_desc,
  ./rpc/jwt_auth,
  std/terminal,
  metrics/chronos_httpserver,
  stew/io2,
  eth/p2p/discoveryv5/[enr, random2],
  beacon_chain/spec/[engine_authentication],
  beacon_chain/validators/keystore_management,
  beacon_chain/[conf, beacon_node, nimbus_binary_common, process_state],
  beacon_chain/nimbus_beacon_node,
  ./[el_sync, nimbus_execution_client]

const defaultMetricsServerPort = 8008

type NStartUpCmd* {.pure.} = enum
  noCommand
  beaconNode
  executionClient

#!fmt: off
type
  XNimbusConf = object
    configFile* {.
      desc: "Loads the configuration from a TOML file",
      name: "config-file"
    .}: Option[InputFile]

    logLevel* {.
      desc:
        "Sets the log level for process and topics (e.g. \"DEBUG; TRACE:discv5,libp2p; REQUIRED:none; DISABLED:none\")",
      defaultValue: "INFO",
      name: "log-level"
    .}: string

    logStdout* {.
      hidden,
      desc:
        "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)",
      defaultValueDesc: "auto",
      defaultValue: StdoutLogKind.Auto,
      name: "log-format"
    .}: StdoutLogKind

    eth2Network* {.
      desc: "The Eth2 network to join", defaultValueDesc: "mainnet", name: "network"
    .}: Option[string]

    dataDirFlag* {.
      desc: "The directory where nimbus will store all blockchain data",
      defaultValueDesc: defaultDataDir("", "<network>"),
      abbr: "d",
      name: "data-dir"
    .}: Option[OutDir]

    metricsEnabled* {.
      desc: "Enable the built-in metrics HTTP server",
      defaultValue: false,
      name: "metrics"
    .}: bool

    metricsPort* {.
      desc: "Listening port of the built-in metrics HTTP server",
      defaultValue: defaultMetricsServerPort,
      defaultValueDesc: $defaultMetricsServerPort,
      name: "metrics-port"
    .}: Port

    metricsAddress* {.
      desc: "Listening IP address of the built-in metrics HTTP server",
      defaultValue: defaultAdminListenAddress,
      defaultValueDesc: $defaultAdminListenAddressDesc,
      name: "metrics-address"
    .}: IpAddress

    numThreads* {.
      defaultValue: 0,
      desc: "Number of worker threads (\"0\" = use as many threads as there are CPU cores available)"
      name: "num-threads" .}: int

    # TODO beacon and execution engine must run on different ports - in order
    #      to keep compatibility with `--tcp-port` that is used in both, use
    #      consecutive ports unless specific ports are set - to be evaluated
    executionTcpPort* {.
      desc: "Listening TCP port for Ethereum DevP2P traffic"
      name: "execution-tcp-port" .}: Option[Port]

    executionUdpPort* {.
      desc: "Listening UDP port for execution node discovery"
      name: "execution-udp-port" .}: Option[Port]

    beaconTcpPort* {.
      desc: "Listening TCP port for Ethereum DevP2P traffic"
      name: "beacon-tcp-port" .}: Option[Port]

    beaconUdpPort* {.
      desc: "Listening UDP port for execution node discovery"
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

    case cmd* {.command, defaultValue: NStartUpCmd.noCommand.}: NStartUpCmd
    of noCommand:
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
    udpPort: Port

var jwtKey: JwtSharedKey

proc dataDir*(config: XNimbusConf): string =
  string config.dataDirFlag.get(
    OutDir defaultDataDir("", config.eth2Network.loadEth2Network().cfg.name)
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
      notice "oops", err = exc.msg

proc runBeaconNode(p: BeaconThreadConfig) {.thread.} =
  var config = makeBannerAndConfig(clientId, BeaconNodeConf)
  let rng = HmacDrbgContext.new()

  let engineUrl =
    EngineApiUrl.init("http://127.0.0.1:8551/", Opt.some(@(distinctBase(jwtKey))))

  config.metricsEnabled = false
  config.elUrls =
    @[
      EngineApiUrlConfigValue(
        url: engineUrl.url, jwtSecret: some toHex(distinctBase(jwtKey))
      )
    ]
  config.statusBarEnabled = false # Multi-threading issues due to logging
  config.tcpPort = p.tcpPort
  config.udpPort = p.udpPort

  # TODO https://github.com/status-im/nim-taskpools/issues/6
  #      share taskpool between bn and ec
  let taskpool = setupTaskpool(config.numThreads)

  info "Launching beacon node",
    version = fullVersionStr,
    bls_backend = $BLS_BACKEND,
    const_preset,
    cmdParams = commandLineParams(),
    config,
    numThreads = taskpool.numThreads

  config.createDumpDirs()

  let metadata = config.loadEth2Network()

  # Updating the config based on the metadata certainly is not beautiful but it
  # works
  for node in metadata.bootstrapNodes:
    config.bootstrapNodes.add node

  block:
    let res =
      if config.trustedSetupFile.isNone:
        conf.loadKzgTrustedSetup()
      else:
        conf.loadKzgTrustedSetup(config.trustedSetupFile.get)
    if res.isErr():
      raiseAssert res.error()

  let stopper = p.tsp.justWait()

  if stopper.finished():
    return

  let node = waitFor BeaconNode.init(rng, config, metadata, taskpool)

  if stopper.finished():
    return

  if p.elSync:
    discard elSyncLoop(node.dag, engineUrl)

  dynamicLogScope(comp = "bn"):
    if node.nickname != "":
      dynamicLogScope(node = node.nickname):
        node.start(stopper)
    else:
      node.start(stopper)

proc runExecutionClient(p: ExecutionThreadConfig) {.thread.} =
  let nimbus = NimbusNode(ctx: newEthContext())

  var config = makeConfig()
  config.metricsEnabled = false
  config.engineApiEnabled = true
  config.jwtSecretValue = some toHex(distinctBase(jwtKey))
  config.agentString = "nimbus"
  config.tcpPort = p.tcpPort
  config.udpPort = p.udpPort

  # TODO https://github.com/status-im/nim-taskpools/issues/6
  #      share taskpool between bn and ec
  let taskpool = setupTaskpool(config.numThreads)

  {.gcsafe.}:
    dynamicLogScope(comp = "ec"):
      nimbus_execution_client.run(nimbus, config, p.tsp.justWait(), taskpool)

# noinline to keep it in stack traces
proc main() {.noinline, raises: [CatchableError].} =
  var
    params = commandLineParams()
    isEC = false
    isBN = false
  for i in 0 ..< params.len:
    try:
      discard NimbusCmd.parseCmdArg(params[i])
      isEC = true
      params.delete(i)
      break
    except ValueError:
      discard
    try:
      discard BNStartUpCmd.parseCmdArg(params[i])
      isBN = true
      params.delete(i)
      break
    except ValueError:
      discard

    try:
      let cmd = NStartUpCmd.parseCmdArg(params[i])

      if cmd == NStartUpCmd.beaconNode:
        isBN = true
        params.delete(i)
        break

      if cmd == NStartUpCmd.executionClient:
        isEC = true
        params.delete(i)
        break
    except ValueError:
      discard

  if isBN:
    nimbus_beacon_node.main()
  elif isEC:
    nimbus_execution_client.main()
  else:
    # Make sure the default nim handlers don't run in any thread
    ProcessState.setupStopHandlers()

    # Make it harder to connect to the (internal) engine - this will of course
    # go away
    discard randomBytes(distinctBase(jwtKey))

    var config = makeBannerAndConfig("Nimbus v0.0.1", XNimbusConf)

    setupLogging(config.logLevel, config.logStdout, none OutFile)
    setupFileLimits()

    if not (checkAndCreateDataDir(string(config.dataDir))):
      # We are unable to access/create data folder or data folder's
      # permissions are insecure.
      quit QuitFailure

    let metricsServer = (waitFor config.initMetricsServer()).valueOr:
      quit 1

    # Nim GC metrics (for the main thread) will be collected in onSecond(), but
    # we disable piggy-backing on other metrics here.
    setSystemMetricsAutomaticUpdate(false)

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
        udpPort: config.executionUdpPort.get(
          Port(uint16(config.udpPort.get(Port(defaultExecutionPort - 1))) + 1)
        ),
      ),
    )

    while not ProcessState.stopIt(notice("Shutting down", reason = it)):
      os.sleep(100)

    waitFor bnStop.fire()
    waitFor ecStop.fire()

    joinThread(bnThread)
    joinThread(ecThread)

when isMainModule:
  main()
