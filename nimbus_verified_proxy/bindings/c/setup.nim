# nimbus_verified_proxy
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronos,
  std/[json, options, strutils],
  stint,
  beacon_chain/spec/digest,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/forks,
  beacon_chain/spec/eth2_apis/eth2_rest_json_serialization,
  beacon_chain/beacon_clock,
  beacon_chain/networking/network_metadata,
  beacon_chain/nimbus_binary_common,
  ../../engine/types,
  ../../engine/engine,
  ../../engine/rpc_frontend,
  ../../lc_backend,
  ../../json_rpc_backend,
  ../../nimbus_verified_proxy_conf,
  ./types,
  ./c_execution_backend,
  ./c_beacon_backend

import ./c_frontend
export c_frontend

proc NimMain() {.importc, exportc, dynlib.}

type ProxyError = object of CatchableError

func getConfiguredChainId(chain: Option[string]): UInt256 =
  let net = chain.get("mainnet").toLowerAscii()
  case net
  of "mainnet": 1.u256
  of "sepolia": 11155111.u256
  of "hoodi": 560048.u256
  else: 1.u256

proc freeNimAllocatedString(res: cstring) {.exported.} =
  deallocShared(res)

proc toUnmanagedPtr[T](x: ref T): ptr T =
  GC_ref(x)
  addr x[]

func asRef[T](x: ptr T): ref T =
  cast[ref T](x)

proc destroy[T](x: ptr T) =
  x[].reset()
  GC_unref(asRef(x))

proc freeContext(ctx: ptr Context) {.exported.} =
  ctx.destroy()

proc processVerifProxyTasks(ctx: ptr Context): cint {.exported.} =
  if ctx.stop:
    return RET_CANCELLED
  if ctx.pendingCalls > 0:
    poll()
  return RET_SUCCESS

proc load(T: type VerifiedProxyConf, configJson: string): T {.raises: [ProxyError].} =
  let jsonNode =
    try:
      parseJson($configJson)
    except CatchableError as e:
      raise newException(ProxyError, "error parsing json: " & e.msg)

  let
    eth2Network = some(jsonNode.getOrDefault("eth2Network").getStr("mainnet"))
    trustedBlockRoot =
      try:
        Eth2Digest.fromHex(jsonNode["trustedBlockRoot"].getStr())
      except KeyError as e:
        raise newException(
          ProxyError, "Couldn't parse `trustedBlockRoot` from JSON config: " & e.msg
        )
    executionApiUrls =
      try:
        parseCmdArg(UrlList, jsonNode["executionApiUrls"].getStr())
      except CatchableError as e:
        raise newException(
          ProxyError, "Couldn't parse `backendUrl` from JSON config: " & e.msg
        )
    beaconApiUrls =
      try:
        parseCmdArg(UrlList, jsonNode["beaconApiUrls"].getStr())
      except CatchableError as e:
        raise newException(
          ProxyError, "Couldn't parse `beaconApiUrls` from JSON config: " & e.msg
        )
    privateTxUrls =
      try:
        let rawUrls = jsonNode.getOrDefault("privateTxUrls").getStr("")
        if rawUrls.len == 0:
          UrlList(@[])
        else:
          parseCmdArg(UrlList, rawUrls)
      except CatchableError as e:
        raise newException(
          ProxyError, "Couldn't parse `privateTxUrls` from JSON config: " & e.msg
        )
    logLevel = jsonNode.getOrDefault("logLevel").getStr("INFO")
    logFormat =
      case jsonNode.getOrDefault("logFormat").getStr("None")
      of "Colors": StdoutLogKind.Colors
      of "NoColors": StdoutLogKind.NoColors
      of "Json": StdoutLogKind.Json
      of "Auto": StdoutLogKind.Auto
      else: StdoutLogKind.None
    maxBlockWalk = jsonNode.getOrDefault("maxBlockWalk").getBiggestInt(1000)
    prllBlkDwnlds = jsonNode.getOrDefault("parallelBlockDownloads").getBiggestInt(10)
    maxLcUpdates = jsonNode.getOrDefault("maxLightClientUpdates").getBiggestInt(128)
    headerStoreLen = jsonNode.getOrDefault("headerStoreLen").getInt(256)
    storageCacheLen = jsonNode.getOrDefault("storageCacheLen").getInt(256)
    codeCacheLen = jsonNode.getOrDefault("codeCacheLen").getInt(64)
    accountCacheLen = jsonNode.getOrDefault("accountCacheLen").getInt(128)
    syncHeaderStore = jsonNode.getOrDefault("syncHeaderStore").getBool(true)
    freezeAtSlotRaw = jsonNode.getOrDefault("freezeAtSlot").getBiggestInt(0)
    freezeAtSlot =
      if freezeAtSlotRaw < 0:
        0'u64
      else:
        uint64(freezeAtSlotRaw)

  return VerifiedProxyConf(
    eth2Network: eth2Network,
    trustedBlockRoot: trustedBlockRoot,
    executionApiUrls: executionApiUrls,
    beaconApiUrls: beaconApiUrls,
    logLevel: logLevel,
    logFormat: logFormat,
    maxBlockWalk:
      if maxBlockWalk < 0:
        uint64(0)
      else:
        uint64(maxBlockWalk),
    headerStoreLen: headerStoreLen,
    storageCacheLen: storageCacheLen,
    codeCacheLen: codeCacheLen,
    accountCacheLen: accountCacheLen,
    parallelBlockDownloads:
      if prllBlkDwnlds < 0:
        uint64(0)
      else:
        uint64(prllBlkDwnlds),
    maxLightClientUpdates:
      if maxLcUpdates <= 0:
        uint64(1)
      else:
        uint64(maxLcUpdates),
    privateTxUrls: privateTxUrls,
    syncHeaderStore: syncHeaderStore,
    freezeAtSlot: freezeAtSlot,
  )

proc run*(
    ctx: ptr Context,
    configJson: string,
    executionTransportProc: ExecutionTransportProc,
    beaconTransportProc: BeaconTransportProc,
) {.async: (raises: [ProxyError, CancelledError]).} =
  let config = VerifiedProxyConf.load(configJson)

  setupLogging(config.logLevel, config.logFormat)

  let
    engineConf = RpcVerificationEngineConf(
      chainId: getConfiguredChainId(config.eth2Network),
      eth2Network: config.eth2Network,
      maxBlockWalk: config.maxBlockWalk,
      headerStoreLen: config.headerStoreLen,
      accountCacheLen: config.accountCacheLen,
      codeCacheLen: config.codeCacheLen,
      storageCacheLen: config.storageCacheLen,
      parallelBlockDownloads: config.parallelBlockDownloads,
      maxLightClientUpdates: config.maxLightClientUpdates,
      trustedBlockRoot: config.trustedBlockRoot,
      syncHeaderStore: config.syncHeaderStore,
      freezeAtSlot: Slot(config.freezeAtSlot),
    )

    engine = RpcVerificationEngine.init(engineConf).valueOr:
      raise newException(ProxyError, error.errMsg)

    usePrivateTx = config.privateTxUrls.len > 0

    regularCaps =
      if usePrivateTx:
        fullExecutionCapabilities - {SendRawTransaction}
      else:
        fullExecutionCapabilities

  for url in config.beaconApiUrls:
    if beaconTransportProc != nil:
      engine.registerBackend(
        getBeaconApiBackend(ctx, url, beaconTransportProc), fullBeaconCapabilities
      )
    else:
      let client = BeaconApiRestClient.init(engine.cfg, engine.forkDigests, url)
      let startRes = client.start()
      if startRes.isErr():
        warn "Error connecting to beacon backend",
          url = url, error = startRes.error.errMsg
        continue
      engine.registerBackend(client.getBeaconApiBackend(), fullBeaconCapabilities)

  for url in config.executionApiUrls:
    if executionTransportProc != nil:
      engine.registerBackend(
        getExecutionApiBackend(ctx, url, executionTransportProc), regularCaps
      )
    else:
      let client = JsonRpcClient.init(url).valueOr:
        error "Error initializing backend client", error = error.errMsg
        continue
      let startRes = await client.start()
      if startRes.isErr():
        error "Error connecting to backend", url = url, error = startRes.error.errMsg
        continue
      engine.registerBackend(client.getExecutionApiBackend(), regularCaps)

  if usePrivateTx:
    for url in config.privateTxUrls:
      if executionTransportProc != nil:
        engine.registerBackend(
          getExecutionApiBackend(ctx, url, executionTransportProc),
          BackendCapabilities({SendRawTransaction}),
        )
      else:
        let client = JsonRpcClient.init(url).valueOr:
          error "Error initializing backend client", error = error.errMsg
          continue
        let startRes = await client.start()
        if startRes.isErr():
          error "Error connecting to backend", url = url, error = startRes.error.errMsg
          continue
        engine.registerBackend(
          client.getExecutionApiBackend(), BackendCapabilities({SendRawTransaction})
        )

  engine.registerDefaultFrontend()
  ctx.frontend = engine.frontend

proc startVerifProxy(
    configJson: cstring,
    executionTransportProc: ExecutionTransportProc,
    beaconTransportProc: BeaconTransportProc,
): ptr Context {.exported.} =
  let ctx = Context.new().toUnmanagedPtr()
  ctx.stop = false

  when defined(setupForeignThreadGc):
    setupForeignThreadGc()

  try:
    waitFor run(ctx, $configJson, executionTransportProc, beaconTransportProc)
  except CatchableError:
    ctx.destroy()
    return nil

  return ctx

proc stopVerifProxy(ctx: ptr Context) {.exported.} =
  when defined(setupForeignThreadGc):
    tearDownForeignThreadGc()
  ctx.stop = true
