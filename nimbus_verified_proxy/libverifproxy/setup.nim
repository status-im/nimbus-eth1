# nimbus_verified_proxy
# Copyright (c) 2024-2025 Status Research & Development GmbH
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

proc load(
    T: type VerifiedProxyConf, configJson: string
): T {.raises: [CatchableError, ValueError].} =
  let jsonNode = parseJson($configJson)

  let
    eth2Network = some(jsonNode.getOrDefault("eth2Network").getStr("mainnet"))
    trustedBlockRoot =
      if jsonNode.contains("trustedBlockRoot"):
        Eth2Digest.fromHex(jsonNode["trustedBlockRoot"].getStr())
      else:
        raise
          newException(ValueError, "`trustedBlockRoot` not specified in JSON config")
    backendUrl =
      if jsonNode.contains("backendUrl"):
        parseCmdArg(Web3Url, jsonNode["backendUrl"].getStr())
      else:
        raise newException(ValueError, "`backendUrl` not specified in JSON config")
    beaconApiUrls =
      if jsonNode.contains("beaconApiUrls"):
        parseCmdArg(UrlList, jsonNode["beaconApiUrls"].getStr())
      else:
        raise newException(ValueError, "`beaconApiUrls` not specified in JSON config")
    logLevel = jsonNode.getOrDefault("logLevel").getStr("INFO")
    logStdout =
      case jsonNode.getOrDefault("logStdout").getStr("None")
      of "Colors": StdoutLogKind.Colors
      of "NoColors": StdoutLogKind.NoColors
      of "Json": StdoutLogKind.Json
      of "Auto": StdoutLogKind.Auto
      else: StdoutLogKind.None
    maxBlockWalk = jsonNode.getOrDefault("maxBlockWalk").getInt(1000)
    headerStoreLen = jsonNode.getOrDefault("headerStoreLen").getInt(256)
    storageCacheLen = jsonNode.getOrDefault("storageCacheLen").getInt(256)
    codeCacheLen = jsonNode.getOrDefault("codeCacheLen").getInt(64)
    accountCacheLen = jsonNode.getOrDefault("accountCacheLen").getInt(128)

  return VerifiedProxyConf(
    eth2Network: eth2Network,
    trustedBlockRoot: trustedBlockRoot,
    backendUrl: backendUrl,
    beaconApiUrls: beaconApiUrls,
    logLevel: logLevel,
    logStdout: logStdout,
    dataDirFlag: none(OutDir),
    maxBlockWalk: uint64(maxBlockWalk),
    headerStoreLen: headerStoreLen,
    storageCacheLen: storageCacheLen,
    codeCacheLen: codeCacheLen,
    accountCacheLen: accountCacheLen,
  )

proc run*(
    ctx: ptr Context, configJson: string
) {.async: (raises: [ValueError, CancelledError, CatchableError]).} =
  let config = VerifiedProxyConf.load(configJson)

  setupLogging(config.logLevel, config.logStdout)

  let
    engineConf = RpcVerificationEngineConf(
      chainId: getConfiguredChainId(config.eth2Network),
      maxBlockWalk: config.maxBlockWalk,
      headerStoreLen: config.headerStoreLen,
      accountCacheLen: config.accountCacheLen,
      codeCacheLen: config.codeCacheLen,
      storageCacheLen: config.storageCacheLen,
    )
    engine = RpcVerificationEngine.init(engineConf)
    lc = LightClient.new(config.eth2Network, some config.trustedBlockRoot)

    # initialize backend for JSON-RPC
    jsonRpcClient = JsonRpcClient.init(config.backendUrl)

    # initialize backend for light client updates
    lcRestClientPool = LCRestClientPool.new(lc.cfg, lc.forkDigests)

  # connect light client to LC by registering on header methods 
  # to use engine header store
  connectLCToEngine(lc, engine)

  # add light client backend
  lc.setBackend(lcRestClientPool.getEthLCBackend())

  # the backend only needs the url to connect to
  engine.backend = jsonRpcClient.getEthApiBackend()

  # inject the frontend into c context
  ctx.frontend = engine.frontend

  # start backend
  var status = await jsonRpcClient.start()
  if status.isErr():
    raise newException(ValueError, status.error)

  # adding endpoints will also start the backend
  lcRestClientPool.addEndpoints(config.beaconApiUrls)

  # this starts the light client manager which is
  # an endless loop
  await lc.start()
