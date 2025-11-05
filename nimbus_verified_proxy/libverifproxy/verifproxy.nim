# nimbus_verified_proxy
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  algorithm,
  json_serialization,
  chronos,
  eth/net/nat,
  std/[atomics, locks, json, net, strutils],
  beacon_chain/spec/[digest, network],
  beacon_chain/nimbus_binary_common,
  web3/[eth_api_types, conversions],
  ../engine/types,
  ../engine/engine,
  ../lc/lc,
  ../lc_backend,
  ../nimbus_verified_proxy,
  ../nimbus_verified_proxy_conf,
  ../json_rpc_backend

{.pragma: exported, cdecl, exportc, dynlib, raises: [].}
{.pragma: exportedConst, exportc, dynlib.}

type
  Task = ref object
    status: int
    response: string
    finished: bool
    cb: CallBackProc

  Context = object
    tasks: seq[Task]
    stop: bool
    frontend: EthApiFrontend

  CallBackProc =
    proc(ctx: ptr Context, status: int, res: cstring) {.cdecl, gcsafe, raises: [].}

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

proc toUnmanagedPtr[T](x: ref T): ptr T =
  GC_ref(x)
  addr x[]

func asRef[T](x: ptr T): ref T =
  cast[ref T](x)

proc destroy[T](x: ptr T) =
  x[].reset()
  GC_unref(asRef(x))

proc createAsyncTaskContext(): ptr Context {.exported.} =
  let ctx = Context.new()
  ctx.toUnmanagedPtr()

proc createTask(cb: CallBackProc): Task =
  let task = Task()
  task.finished = false
  task.cb = cb
  task

proc freeResponse(res: cstring) {.exported.} =
  deallocShared(res)

proc freeContext(ctx: ptr Context) {.exported.} =
  ctx.destroy()

proc alloc(str: string): cstring =
  var ret = cast[cstring](allocShared(str.len + 1))
  let s = cast[seq[char]](str)
  for i in 0 ..< str.len:
    ret[i] = s[i]
  ret[str.len] = '\0'
  return ret

# NOTE: this is not the C callback. This is just a callback for the future
template callbackToC(ctx: ptr Context, cb: CallBackProc, asyncCall: untyped) =
  let task = createTask(cb)
  ctx.tasks.add(task)

  let fut = asyncCall

  fut.addCallback proc(_: pointer) {.gcsafe.} =
    if fut.cancelled():
      task.response = Json.encode(fut.error())
      task.finished = true
      task.status = -2
    elif fut.failed():
      task.response = Json.encode(fut.error())
      task.finished = true
      task.status = -1
    else:
      task.response = Json.encode(fut.value())
      task.status = 0
      task.finished = true

proc eth_blockNumber(ctx: ptr Context, cb: CallBackProc) {.exported.} =
  callbackToC(ctx, cb):
    ctx.frontend.eth_blockNumber()

proc eth_getBalance(
    ctx: ptr Context, address: cstring, blockTag: cstring, cb: CallBackProc
) {.exported.} =
  let
    addressTyped =
      try:
        Address.fromHex($address)
      except ValueError as e:
        cb(ctx, -3, alloc(e.msg))
        return

    blockTagTyped =
      try:
        BlockTag(kind: bidNumber, number: Quantity(parseBiggestUInt($blockTag)))
      except ValueError:
        BlockTag(kind: bidAlias, alias: $blockTag)

  callbackToC(ctx, cb):
    ctx.frontend.eth_getBalance(addressTyped, blockTagTyped)

proc pollAsyncTaskEngine(ctx: ptr Context) {.exported.} =
  var delList: seq[int] = @[]

  let taskLen = ctx.tasks.len
  for idx in 0 ..< taskLen:
    let task = ctx.tasks[idx]
    if task.finished:
      task.cb(ctx, task.status, alloc(task.response))
      delList.add(idx)

  # sequence changes as we delete so delting in descending order
  for i in delList.sorted(SortOrder.Descending):
    ctx.tasks.delete(i)

  if ctx.tasks.len > 0:
    poll()

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

proc run(
    ctx: ptr Context, configJson: string
) {.async: (raises: [ValueError, CancelledError, CatchableError]).} =
  try:
    initLib()
  except Exception as err:
    raise newException(CancelledError, err.msg)

  let config = VerifiedProxyConf.load($configJson)

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

# TODO: if frontend is accessed if this fails then it throws a sefault
# TODO: there is log leakage(at WARN level) even when logging is set to FATAL and stdout is set to None
proc startVerifProxy(
    ctx: ptr Context, configJson: cstring, cb: CallBackProc
) {.exported.} =
  let task = createTask(cb)

  ctx.tasks.add(task)

  let fut = run(ctx, $configJson)

  fut.addCallback proc(udata: pointer) {.gcsafe.} =
    if fut.cancelled():
      task.response = Json.encode(fut.error())
      task.finished = true
      task.status = -2
    elif fut.failed():
      task.response = Json.encode(fut.error())
      task.finished = true
      task.status = -1
    else:
      task.response = "success" #result is void hence we just provide a string
      task.status = 0
      task.finished = true

proc stopVerifProxy(ctx: ptr Context) {.exported.} =
  ctx.stop = true

# C-callable: downloads a page and returns a heap-allocated C string.
proc nonBusySleep(ctx: ptr Context, secs: cint, cb: CallBackProc) {.exported.} =
  let task = createTask(cb)

  ctx.tasks.add(task)

  let fut = sleepAsync((secs).seconds)

  fut.addCallback proc(_: pointer) {.gcsafe.} =
    if fut.cancelled:
      task.response = "cancelled"
      task.finished = true
      task.status = -2
    elif fut.failed():
      task.response = "failed"
      task.finished = true
      task.status = -1
    else:
      try:
        task.response = "slept"
        task.status = 0
      except CatchableError as e:
        task.response = e.msg
        task.status = -1
      finally:
        task.finished = true
