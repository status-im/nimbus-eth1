# nimbus_verified_proxy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[atomics, json, os, strutils],
  ../nimbus_verified_proxy,
  ../nimbus_verified_proxy_conf

proc quit*() {.exportc, dynlib.} =
  echo "Quitting"

proc NimMain() {.importc, exportc, dynlib.}

var initialized: Atomic[bool]

proc initLib() =
  if not initialized.exchange(true):
    NimMain() # Every Nim library needs to call `NimMain` once exactly
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
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

    run(myConfig, ctx)
  except Exception as err:
    echo "Exception when running ", getCurrentExceptionMsg(), err.getStackTrace()
    ctx.onHeader(getCurrentExceptionMsg(), 3)
    ctx.cleanup()

  #[let node = parseConfigAndRun(ctx.configJson)

  while not ctx[].stop: # and node.running:
    let timeout = sleepAsync(100.millis)
    waitFor timeout

  # do cleanup
  node.stop()]#

proc startVerifProxy*(
    configJson: cstring, onHeader: OnHeaderCallback
): ptr Context {.exportc, dynlib.} =
  initLib()

  let ctx = createShared(Context, 1)
  ctx.configJson = cast[cstring](allocShared0(len(configJson) + 1))
  ctx.onHeader = onHeader
  copyMem(ctx.configJson, configJson, len(configJson))

  try:
    createThread(ctx.thread, runContext, ctx)
  except Exception as err:
    echo "Exception when attempting to invoke createThread ",
      getCurrentExceptionMsg(), err.getStackTrace()
    ctx.onHeader(getCurrentExceptionMsg(), 3)
    ctx.cleanup()
  return ctx

proc stopVerifProxy*(ctx: ptr Context) {.exportc, dynlib.} =
  ctx.stop = true
