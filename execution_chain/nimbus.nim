import ../execution_chain/compile_info

import web3/primitives, chronos

proc workaround*(): int {.exportc.} =
  # TODO https://github.com/nim-lang/Nim/issues/24844
  return int(Future[Quantity]().internalValue)

import
  std/[os, net, options],
  chronos/threadsync,
  chronicles,
  eth/net/nat,
  metrics,
  ./constants,
  ./nimbus_desc,
  ./core/lazy_kzg,
  ./db/core_db/persistent,
  ./db/storage_types,
  ./sync/wire_protocol,
  ./common/chain_config_hash,
  std/[terminal, exitprocs],
  metrics/chronos_httpserver,
  stew/io2,
  eth/p2p/discoveryv5/[enr, random2],
  beacon_chain/networking/[network_metadata_downloads],
  beacon_chain/spec/[engine_authentication],
  beacon_chain/validators/keystore_management,
  beacon_chain/[beacon_node, nimbus_binary_common, process_state],
  beacon_chain/nimbus_beacon_node,
  ./nimbus_execution_client

const defaultMetricsServerPort = 8008

type NStartUpCmd* {.pure.} = enum
  noCommand
  beaconNode
  executionClient

#!fmt: off
type XNimbusConf = object
  configFile* {.desc: "Loads the configuration from a TOML file", name: "config-file".}:
    Option[InputFile]
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

  dataDir* {.
    desc: "The directory where nimbus will store all blockchain data",
    defaultValue: config.defaultDataDir(),
    defaultValueDesc: "",
    abbr: "d",
    name: "data-dir"
  .}: OutDir

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

  case cmd* {.command, defaultValue: NStartUpCmd.noCommand.}: NStartUpCmd
  of noCommand:
    discard
  of beaconNode:
    discard
  of executionClient:
    discard

#!fmt: on

proc justWait(tsp: ThreadSignalPtr) {.async: (raises: [CancelledError]).} =
  try:
    await tsp.wait()
  except AsyncError as exc:
    notice "Waiting failed", err = exc.msg

proc runBeaconNode(p: tuple[tsp: ThreadSignalPtr]) {.thread.} =
  var config = makeBannerAndConfig(clientId, BeaconNodeConf)
  let rng = HmacDrbgContext.new()

  config.metricsEnabled = false
  config.elUrls =
    @[
      EngineApiUrlConfigValue(
        url: "http://127.0.0.1:8551/",
        jwtSecret:
          some "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3",
      )
    ]
  config.statusBarEnabled = false # Multi-threading issues due to logging

  # TODO share taskpool between bn and ec
  let taskpool = setupTaskpool(config.numThreads)

  doRunBeaconNode(config, rng, p.tsp.justWait(), taskpool)

proc runExecutionClient(p: tuple[tsp: ThreadSignalPtr]) {.thread.} =
  let nimbus = NimbusNode(ctx: newEthContext())

  var config = makeConfig()
  config.metricsEnabled = false
  config.engineApiEnabled = true
  config.jwtSecretValue =
    some "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
  config.agentString = "nimbus"

  # TODO share taskpool between bn and ec
  let taskpool = setupTaskpool(config.numThreads)

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
    # Mask stop signals in downstream threads - this should help ensure that our
    # waitSignal gets the signal on os' that work this way
    discard ProcessState.ignoreStopSignalsInThread()

    var config = makeBannerAndConfig("Nimbus v0.0.1", XNimbusConf)

    setupLogging(config.logLevel, config.logStdout, none OutFile)
    setupFileLimits()

    # Make sure the default nim handlers don't run in any thread
    ProcessState.setupStopHandlers()

    if not (checkAndCreateDataDir(string(config.dataDir))):
      # We are unable to access/create data folder or data folder's
      # permissions are insecure.
      quit QuitFailure

    let metricsServer = (waitFor config.initMetricsServer()).valueOr:
      quit 1

    var bnThread: Thread[(ThreadSignalPtr,)]
    let bnStop = ThreadSignalPtr.new().expect("working ThreadSignalPtr")
    createThread(bnThread, runBeaconNode, (bnStop,))

    var ecThread: Thread[(ThreadSignalPtr,)]
    let ecStop = ThreadSignalPtr.new().expect("working ThreadSignalPtr")
    createThread(ecThread, runExecutionClient, (ecStop,))

    waitFor ProcessState.waitStopSignals()

    notice "Stopping main thread"

    waitFor bnStop.fire()
    waitFor ecStop.fire()

    joinThread(bnThread)
    joinThread(ecThread)

when isMainModule:
  main()
