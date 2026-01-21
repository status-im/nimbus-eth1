# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronos,
  std/json,
  beacon_chain/spec/digest,
  beacon_chain/nimbus_binary_common,
  ../engine/types,
  ../engine/engine,
  ../lc/lc,
  ../lc_backend,
  ../nimbus_verified_proxy,
  ../nimbus_verified_proxy_conf,
  ../json_rpc_backend,
  ./types

type ProxyError = object of CatchableError

proc load(T: type VerifiedProxyConf, configJson: string): T {.raises: [ProxyError].} =
  let jsonNode =
    try:
      parseJson($configJson)
    except CatchableError as e: # IOError, ValueError and OSError
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
    backendUrls =
      try:
        parseCmdArg(seq[Web3Url], jsonNode["backendUrls"].getStr())
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
    headerStoreLen = jsonNode.getOrDefault("headerStoreLen").getInt(256)
    storageCacheLen = jsonNode.getOrDefault("storageCacheLen").getInt(256)
    codeCacheLen = jsonNode.getOrDefault("codeCacheLen").getInt(64)
    accountCacheLen = jsonNode.getOrDefault("accountCacheLen").getInt(128)

  return VerifiedProxyConf(
    eth2Network: eth2Network,
    trustedBlockRoot: trustedBlockRoot,
    backendUrls: backendUrls,
    beaconApiUrls: beaconApiUrls,
    logLevel: logLevel,
    logFormat: logFormat,
    dataDirFlag: none(OutDir),
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
  )

proc run*(
    ctx: ptr Context, configJson: string
) {.async: (raises: [ProxyError, CancelledError]).} =
  let config = VerifiedProxyConf.load(configJson)

  setupLogging(config.logLevel, config.logFormat)

  let
    engineConf = RpcVerificationEngineConf(
      chainId: getConfiguredChainId(config.eth2Network),
      maxBlockWalk: config.maxBlockWalk,
      headerStoreLen: config.headerStoreLen,
      accountCacheLen: config.accountCacheLen,
      codeCacheLen: config.codeCacheLen,
      storageCacheLen: config.storageCacheLen,
      parallelBlockDownloads: config.parallelBlockDownloads,
    )
    engine = RpcVerificationEngine.init(engineConf).valueOr:
      raise newException(ProxyError, error.errMsg)
    lc = LightClient.new(config.eth2Network, some config.trustedBlockRoot)

    # initialize backend for JSON-RPC
    jsonRpcClientPool = JsonRpcClientPool.new()

    # initialize backend for light client updates
    lcRestClientPool = LCRestClientPool.new(lc.cfg, lc.forkDigests)

  # connect light client to LC by registering on header methods 
  # to use engine header store
  connectLCToEngine(lc, engine)

  # add light client backend
  lc.setBackend(lcRestClientPool.getEthLCBackend())

  # the backend only needs the url to connect to
  engine.backend = jsonRpcClientPool.getEthApiBackend()

  # inject the frontend into c context
  ctx.frontend = engine.frontend

  # start backend
  var status = await jsonRpcClientPool.addEndpoints(config.backendUrls)
  if status.isErr():
    raise newException(ProxyError, status.error.errMsg)

  # adding endpoints will also start the backend
  if lcRestClientPool.addEndpoints(config.beaconApiUrls).isErr():
    raise newException(ProxyError, "Couldn't add endpoints for light client queries")

  # this starts the light client manager which is
  # an endless loop
  await lc.start()
