# nimbus_verified_proxy
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[atomics, json, net],
  beacon_chain/spec/[digest, network],
  beacon_chain/nimbus_binary_common,
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
  const defaultListenAddress = (static parseIpAddress("0.0.0.0"))
  let str = $ctx.configJson
  try:
    let jsonNode = parseJson(str)

    let myConfig = VerifiedProxyConf(
      eth2Network: some(jsonNode["eth2Network"].getStr()),
      trustedBlockRoot: Eth2Digest.fromHex(jsonNode["trustedBlockRoot"].getStr()),
      backendUrl: parseCmdArg(Web3Url, jsonNode["backendUrl"].getStr()),
      frontendUrl: parseCmdArg(Web3Url, jsonNode["frontendUrl"].getStr()),
      lcEndpoints: parseCmdArg(UrlList, jsonNode["lcEndpoints"].getStr()),
      logLevel: jsonNode["LogLevel"].getStr(),
      logStdout: StdoutLogKind.Auto,
      dataDirFlag: none(OutDir),
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
