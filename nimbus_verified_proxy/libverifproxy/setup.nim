# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronos,
  std/json,
  stint,
  eth/common/keys, # used for keys.rng
  beacon_chain/spec/digest,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/forks,
  beacon_chain/spec/eth2_apis/eth2_rest_json_serialization,
  beacon_chain/conf,
  beacon_chain/beacon_clock,
  beacon_chain/networking/network_metadata,
  beacon_chain/nimbus_binary_common,
  web3/[eth_api_types, conversions],
  ../engine/types,
  ../engine/engine,
  ../engine/rpc_frontend,
  ../lc_backend,
  ../json_rpc_backend,
  ../nimbus_verified_proxy,
  ../nimbus_verified_proxy_conf,
  ./types

type ProxyError = object of CatchableError

proc transportCallback[T](
    ctx: ptr Context, status: cint, res: cstring, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let data = cast[ref CallBackData[T]](userData)
  if status == RET_SUCCESS:
    # using $ on C allocated strings copies the context therefore it is safe to free the
    # pointer on the C side. Also allows managing the memeory on one end only.
    let deserResult = unpackArg($res, T)
    if deserResult.isErr():
      data.fut.complete(
        EngineResult[T].err((BackendDecodingError, deserResult.error, UNTAGGED))
      )
      return
    data.fut.complete(EngineResult[T].ok(deserResult.get()))
  elif status == RET_ERROR:
    data.fut.complete(EngineResult[T].err((BackendFetchError, $res, UNTAGGED)))
  elif status == RET_CANCELLED:
    data.fut.fail((ref CancelledError)(msg: $res))

proc getExecutionApiBackend*(
    ctx: ptr Context, url: string, transportProc: ExecutionTransportProc
): ExecutionApiBackend =
  let
    rng = keys.newRng()
    ethChainIdProc = proc(): Future[EngineResult[UInt256]] {.
        async: (raises: [CancelledError])
    .} =
      let fut =
        Future[EngineResult[UInt256]].Raising([CancelledError]).init("blkByHash")

      transportProc(
        ctx,
        alloc(url),
        "eth_chainId",
        "[]",
        transportCallback[UInt256],
        createCbData(fut),
      )
      await fut

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      let
        fut =
          Future[EngineResult[BlockObject]].Raising([CancelledError]).init("blkByHash")
        fullFlagStr = if fullTransactions: "true" else: "false"
        blkHashSer = packArg(blkHash).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params = "[" & blkHashSer & ", " & fullFlagStr & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_getBlockByHash",
        alloc(params),
        transportCallback[BlockObject],
        createCbData(fut),
      )
      await fut

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      let
        fut = Future[EngineResult[BlockObject]].Raising([CancelledError]).init(
            "blkByNumber"
          )
        fullFlagStr = if fullTransactions: "true" else: "false"
        blkNumSer = packArg(blkNum).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params = "[" & blkNumSer & ", " & fullFlagStr & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_getBlockByNumber",
        alloc(params),
        transportCallback[BlockObject],
        createCbData(fut),
      )
      await fut

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
      let
        fut =
          Future[EngineResult[ProofResponse]].Raising([CancelledError]).init("getProof")
        addressSer = packArg(address).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        slotsSer = packArg(slots).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))

        params = "[" & addressSer & ", " & slotsSer & ", " & blockIdSer & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_getProof",
        alloc(params),
        transportCallback[ProofResponse],
        createCbData(fut),
      )
      await fut

    createAccessListProc = proc(
        txArgs: TransactionArgs, blockId: BlockTag
    ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).} =
      let
        fut = Future[EngineResult[AccessListResult]].Raising([CancelledError]).init(
            "createAL"
          )
        txArgsSer = packArg(txArgs).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params = "[" & txArgsSer & ", " & blockIdSer & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_createAccessList",
        alloc(params),
        transportCallback[AccessListResult],
        createCbData(fut),
      )
      await fut

    getCodeProc = proc(
        address: Address, blockId: BlockTag
    ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
      let
        fut = Future[EngineResult[seq[byte]]].Raising([CancelledError]).init("getCode")
        addressSer = packArg(address).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params = "[" & addressSer & ", " & blockIdSer & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_getCode",
        alloc(params),
        transportCallback[seq[byte]],
        createCbData(fut),
      )
      await fut

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
      let
        fut = Future[EngineResult[TransactionObject]].Raising([CancelledError]).init(
            "getTxByHash"
          )
        txHashSer = packArg(txHash).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params = "[" & txHashSer & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_getTransactionByHash",
        alloc(params),
        transportCallback[TransactionObject],
        createCbData(fut),
      )
      await fut

    getTransactionReceiptProc = proc(
        txHash: Hash32
    ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).} =
      let
        fut = Future[EngineResult[ReceiptObject]].Raising([CancelledError]).init(
            "getRxByHash"
          )
        txHashSer = packArg(txHash).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params = "[" & txHashSer & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_getTransactionReceipt",
        alloc(params),
        transportCallback[ReceiptObject],
        createCbData(fut),
      )
      await fut

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.
        async: (raises: [CancelledError])
    .} =
      let
        fut = Future[EngineResult[Opt[seq[ReceiptObject]]]]
          .Raising([CancelledError])
          .init("getBlockRxs")
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params = "[" & blockIdSer & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_getBlockReceipts",
        alloc(params),
        transportCallback[Opt[seq[ReceiptObject]]],
        createCbData(fut),
      )
      await fut

    getLogsProc = proc(
        filterOptions: FilterOptions
    ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
      let
        fut =
          Future[EngineResult[seq[LogObject]]].Raising([CancelledError]).init("getLogs")
        filterOptionsSer = packArg(filterOptions).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params = "[" & filterOptionsSer & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_getLogs",
        alloc(params),
        transportCallback[seq[LogObject]],
        createCbData(fut),
      )
      await fut

    feeHistoryProc = proc(
        blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: seq[int]
    ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).} =
      let
        fut = Future[EngineResult[FeeHistoryResult]].Raising([CancelledError]).init(
            "feeHistory"
          )
        blockCountSer = packArg(blockCount).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        newestBlockSer = packArg(newestBlock).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        rewardPercentilesSer = packArg(rewardPercentiles).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params =
          "[" & blockCountSer & ", " & newestBlockSer & ", " & rewardPercentilesSer & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_feeHistory",
        alloc(params),
        transportCallback[FeeHistoryResult],
        createCbData(fut),
      )
      await fut

    sendRawTxProc = proc(
        txBytes: seq[byte]
    ): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
      let
        fut = Future[EngineResult[Hash32]].Raising([CancelledError]).init("sendRawTx")
        txBytesSer = packArg(txBytes).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params = "[" & txBytesSer & "]"

      transportProc(
        ctx,
        alloc(url),
        "eth_sendRawTransaction",
        alloc(params),
        transportCallback[Hash32],
        createCbData(fut),
      )
      await fut

  ExecutionApiBackend(
    eth_chainId: ethChainIdProc,
    eth_getBlockByHash: getBlockByHashProc,
    eth_getBlockByNumber: getBlockByNumberProc,
    eth_getProof: getProofProc,
    eth_createAccessList: createAccessListProc,
    eth_getCode: getCodeProc,
    eth_getBlockReceipts: getBlockReceiptsProc,
    eth_getLogs: getLogsProc,
    eth_getTransactionByHash: getTransactionByHashProc,
    eth_getTransactionReceipt: getTransactionReceiptProc,
    eth_feeHistory: feeHistoryProc,
    eth_sendRawTransaction: sendRawTxProc,
  )

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
    headerStoreLen = jsonNode.getOrDefault("headerStoreLen").getInt(256)
    storageCacheLen = jsonNode.getOrDefault("storageCacheLen").getInt(256)
    codeCacheLen = jsonNode.getOrDefault("codeCacheLen").getInt(64)
    accountCacheLen = jsonNode.getOrDefault("accountCacheLen").getInt(128)

  return VerifiedProxyConf(
    eth2Network: eth2Network,
    trustedBlockRoot: trustedBlockRoot,
    executionApiUrls: executionApiUrls,
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
    privateTxUrls: privateTxUrls,
  )

proc beaconTransportCallback[T](
    ctx: ptr Context, status: cint, res: cstring, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let data = cast[ref CallBackData[T]](userData)
  if status == RET_SUCCESS:
    try:
      data.fut.complete(
        EngineResult[T].ok(RestJson.decode($res, T, allowUnknownFields = true))
      )
    except SerializationError as e:
      data.fut.complete(EngineResult[T].err((BackendDecodingError, e.msg, UNTAGGED)))
  elif status == RET_ERROR:
    data.fut.complete(EngineResult[T].err((BackendFetchError, $res, UNTAGGED)))
  elif status == RET_CANCELLED:
    data.fut.fail((ref CancelledError)(msg: $res))

proc getBeaconApiBackend*(
    ctx: ptr Context, url: string, transportProc: BeaconTransportProc
): BeaconApiBackend =
  let
    bootstrapProc = proc(
        blockRoot: Eth2Digest
    ): Future[EngineResult[ForkedLightClientBootstrap]] {.
        async: (raises: [CancelledError])
    .} =
      let
        fut = Future[EngineResult[ForkedLightClientBootstrap]]
          .Raising([CancelledError])
          .init("lcBootstrap")
        params = alloc("{\"block_root\": \"" & $blockRoot & "\"}")

      transportProc(
        ctx,
        alloc(url),
        "getLightClientBootstrap",
        params,
        beaconTransportCallback[ForkedLightClientBootstrap],
        createCbData(fut),
      )
      await fut

    updatesProc = proc(
        startPeriod: SyncCommitteePeriod, count: uint64
    ): Future[EngineResult[seq[ForkedLightClientUpdate]]] {.
        async: (raises: [CancelledError])
    .} =
      let
        fut = Future[EngineResult[seq[ForkedLightClientUpdate]]]
          .Raising([CancelledError])
          .init("lcUpdates")
        params = alloc(
          "{\"start_period\": " & $startPeriod.uint64 & ", \"count\": " & $count & "}"
        )

      transportProc(
        ctx,
        alloc(url),
        "getLightClientUpdatesByRange",
        params,
        beaconTransportCallback[seq[ForkedLightClientUpdate]],
        createCbData(fut),
      )
      await fut

    optimisticProc = proc(): Future[EngineResult[ForkedLightClientOptimisticUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      let
        fut = Future[EngineResult[ForkedLightClientOptimisticUpdate]]
          .Raising([CancelledError])
          .init("lcOptimistic")
        params = alloc("{}")

      transportProc(
        ctx,
        alloc(url),
        "getLightClientOptimisticUpdate",
        params,
        beaconTransportCallback[ForkedLightClientOptimisticUpdate],
        createCbData(fut),
      )
      await fut

    finalityProc = proc(): Future[EngineResult[ForkedLightClientFinalityUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      let
        fut = Future[EngineResult[ForkedLightClientFinalityUpdate]]
          .Raising([CancelledError])
          .init("lcFinality")
        params = alloc("{}")

      transportProc(
        ctx,
        alloc(url),
        "getLightClientFinalityUpdate",
        params,
        beaconTransportCallback[ForkedLightClientFinalityUpdate],
        createCbData(fut),
      )
      await fut

  BeaconApiBackend(
    getLightClientBootstrap: bootstrapProc,
    getLightClientUpdatesByRange: updatesProc,
    getLightClientOptimisticUpdate: optimisticProc,
    getLightClientFinalityUpdate: finalityProc,
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
      trustedBlockRoot: config.trustedBlockRoot,
      syncHeaderStore: config.syncHeaderStore,
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
    # Set up beacon backends — prefer the caller-supplied transport
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
    # Set up execution backends — prefer the caller-supplied transport
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
      # Set up execution backends — prefer the caller-supplied transport
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

  # inject the frontend into c context
  ctx.frontend = engine.frontend
