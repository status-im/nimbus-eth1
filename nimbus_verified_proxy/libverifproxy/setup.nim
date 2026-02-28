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
  beacon_chain/nimbus_binary_common,
  web3/[eth_api_types, conversions],
  ../engine/types,
  ../engine/engine,
  ../lc/lc,
  ../lc_backend,
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
      data.fut.complete(EngineResult[T].err((BackendDecodingError, deserResult.error)))
      return
    data.fut.complete(EngineResult[T].ok(deserResult.get()))
  elif status == RET_ERROR:
    data.fut.complete(EngineResult[T].err((BackendError, $res)))
  elif status == RET_CANCELLED:
    data.fut.fail((ref CancelledError)(msg: $res))

proc getRandomBackendUrl(rng: ref HmacDrbgContext, urls: seq[Web3Url]): string =
  var randomNum: uint64
  rng[].generate(randomNum)

  # NOTE: we use the mod operator to bring the random number into range
  # this introduces a bias in the output distribution but is negligible
  # for this use case. The bias becomes insignificant when score filters
  # are used to select clients in the future.
  let url = urls[randomNum mod uint64(urls.len)]

  url.web3Url

proc getEthApiBackend*(
    ctx: ptr Context, urls: seq[Web3Url], transportProc: TransportProc
): EthApiBackend =
  let
    rng = keys.newRng()
    ethChainIdProc = proc(): Future[EngineResult[UInt256]] {.
        async: (raises: [CancelledError])
    .} =
      let
        fut = Future[EngineResult[UInt256]].Raising([CancelledError]).init("blkByHash")
        url = getRandomBackendUrl(rng, urls)
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
          return err((BackendEncodingError, error))
        params = "[" & blkHashSer & ", " & fullFlagStr & "]"
        url = getRandomBackendUrl(rng, urls)

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
          return err((BackendEncodingError, error))
        params = "[" & blkNumSer & ", " & fullFlagStr & "]"
        url = getRandomBackendUrl(rng, urls)

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
          return err((BackendEncodingError, error))
        slotsSer = packArg(slots).valueOr:
          return err((BackendEncodingError, error))
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error))

        params = "[" & addressSer & ", " & slotsSer & ", " & blockIdSer & "]"
        url = getRandomBackendUrl(rng, urls)

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
          return err((BackendEncodingError, error))
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error))
        params = "[" & txArgsSer & ", " & blockIdSer & "]"
        url = getRandomBackendUrl(rng, urls)

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
          return err((BackendEncodingError, error))
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error))
        params = "[" & addressSer & ", " & blockIdSer & "]"
        url = getRandomBackendUrl(rng, urls)

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
          return err((BackendEncodingError, error))
        params = "[" & txHashSer & "]"
        url = getRandomBackendUrl(rng, urls)

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
          return err((BackendEncodingError, error))
        params = "[" & txHashSer & "]"
        url = getRandomBackendUrl(rng, urls)

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
          return err((BackendEncodingError, error))
        params = "[" & blockIdSer & "]"
        url = getRandomBackendUrl(rng, urls)

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
          return err((BackendEncodingError, error))
        params = "[" & filterOptionsSer & "]"
        url = getRandomBackendUrl(rng, urls)

      transportProc(
        ctx,
        alloc(url),
        "eth_getLogs",
        alloc(params),
        transportCallback[seq[LogObject]],
        createCbData(fut),
      )
      await fut

    sendRawTxProc = proc(
        txBytes: seq[byte]
    ): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
      let
        fut = Future[EngineResult[Hash32]].Raising([CancelledError]).init("sendRawTx")
        txBytesSer = packArg(txBytes).valueOr:
          return err((BackendEncodingError, error))
        params = "[" & txBytesSer & "]"
        url = getRandomBackendUrl(rng, urls)

      transportProc(
        ctx,
        alloc(url),
        "eth_sendRawTransaction",
        alloc(params),
        transportCallback[Hash32],
        createCbData(fut),
      )
      await fut

  EthApiBackend(
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
        parseCmdArg(seq[Web3Url], jsonNode["executionApiUrls"].getStr())
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
  )

proc run*(
    ctx: ptr Context, configJson: string, transportProc: TransportProc
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

    # initialize backend for light client updates
    lcRestClientPool = LCRestClientPool.new(lc.cfg, lc.forkDigests)

  # connect light client to LC by registering on header methods 
  # to use engine header store
  connectLCToEngine(lc, engine)

  # add light client backend
  lc.setBackend(lcRestClientPool.getEthLCBackend())

  engine.backends = @[getEthApiBackend(ctx, config.executionApiUrls, transportProc)]

  # inject the frontend into c context
  ctx.frontend = engine.frontend

  # adding endpoints will also start the backend
  let status = lcRestClientPool.addEndpoints(config.beaconApiUrls)
  if status.isErr():
    raise newException(
      ProxyError, "Couldn't add endpoints for light client queries" & status.error
    )

  # this starts the light client manager which is
  # an endless loop
  await lc.start()
