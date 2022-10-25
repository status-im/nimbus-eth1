import
  std/[atomics, json, os, strutils],
  ../nimbus_verified_proxy,
  ../nimbus_verified_proxy_conf

proc quit*() {.exportc, dynlib.} = 
  echo "Quitting"

proc NimMain() {.importc.}

var initialized: Atomic[bool]

type Context* = object
  thread*: Thread[ptr Context]
  configJson*: cstring
  stop*: bool
  onHeader*: OnHeaderCallback

proc initLib() =
   if not initialized.exchange(true):
     NimMain() # Every Nim library needs to call `NimMain` once exactly
   when declared(setupForeignThreadGc): setupForeignThreadGc()
   when declared(nimGC_setStackBottom):
     var locals {.volatile, noinit.}: pointer
     locals = addr(locals)
     nimGC_setStackBottom(locals)


proc runContext(ctx: ptr Context) {.thread.} =
  let str = $ctx.configJson
  try:
    let jsonNode = parseJson(str)

    let rpcAddr = jsonNode["RpcAddress"].getStr()
    let myConfig = VerifiedProxyConf(
      rpcAddress: ValidIpAddress.init(rpcAddr), 
      listenAddress: defaultListenAddress, 
      eth2Network: some(jsonNode["Eth2Network"].getStr()), 
      trustedBlockRoot: Eth2Digest.fromHex(jsonNode["TrustedBlockRoot"].getStr()),
      web3Url: parseCmdArg(Web3Url, jsonNode["Web3Url"].getStr()),
      rpcPort: Port(jsonNode["RpcPort"].getInt()),
      logLevel: jsonNode["LogLevel"].getStr(),
      maxPeers: 160,
      nat: NatConfig(hasExtIp: false, nat: NatAny),
      logStdout: StdoutLogKind.Auto,
      dataDir: OutDir(defaultVerifiedProxyDataDir()),
      tcpPort: Port(defaultEth2TcpPort),
      udpPort: Port(defaultEth2TcpPort),
      agentString: "nimbus",
      discv5Enabled: true,
    )

    run(myConfig, ctx.onHeader)
  except Exception as err:
    echo "Exception when running ", getCurrentExceptionMsg(), err.getStackTrace() 


  #[let node = parseConfigAndRun(ctx.configJson)

  while not ctx[].stop: # and node.running:
    let timeout = sleepAsync(100.millis)
    waitFor timeout

  # do cleanup
  node.stop()]#

proc startLightClientProxy*(configJson: cstring, onHeader: OnHeaderCallback): ptr Context {.exportc, dynlib.} =
  initLib()

  let ctx = createShared(Context, 1)
  ctx.configJson = cast[cstring](allocShared0(len(configJson) + 1))
  ctx.onHeader = onHeader
  copyMem(ctx.configJson, configJson, len(configJson))

  try:
    createThread(ctx.thread, runContext, ctx)
  except Exception as err:
    echo "Exception when attempting to invoke createThread ", getCurrentExceptionMsg(), err.getStackTrace() 
  return ctx


