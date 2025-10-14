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
  std/[atomics, locks, json, net],
  beacon_chain/spec/[digest, network],
  beacon_chain/nimbus_binary_common,
  ../engine/types,
  ../engine/engine,
  ../nimbus_verified_proxy,
  ../nimbus_verified_proxy_conf,
  ../json_rpc_backend

{.pragma: exported, cdecl, exportc, dynlib, raises: [].}
{.pragma: exportedConst, exportc, dynlib.}

type
  CallBackProc = proc(status: int, res: cstring) {.cdecl, gcsafe, raises: [].}

  Task = ref object 
    status: int
    response: string
    finished: bool
    cb: CallBackProc

  Context = object
    lock: Lock
    tasks: seq[Task]
    stop: bool
    frontend : EthApiFrontend

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
  ctx.lock.initLock()
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

proc eth_blockNumber(ctx: ptr Context, cb: CallBackProc) {.exported.} =
  let task = createTask(cb)

  try:
    ctx.lock.acquire()
    ctx.tasks.add(task)
  finally:
    ctx.lock.release()

  let fut = ctx.frontend.eth_blockNumber()

  fut.addCallback proc (_: pointer) {.gcsafe.} =
    try:
      ctx.lock.acquire()
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
    finally:
      ctx.lock.release()

proc pollAsyncTaskEngine(ctx: ptr Context) {.exported.} =
  var delList: seq[int] = @[]

  let taskLen = ctx.tasks.len
  for idx in 0..<taskLen:
    let task = ctx.tasks[idx]
    if task.finished:
      try:
        ctx.lock.acquire()
        task.cb(task.status, alloc(task.response))
        delList.add(idx)
      finally:
        ctx.lock.release()

  # sequence changes as we delete so delting in descending order
  for i in delList.sorted(SortOrder.Descending):
    try:
      ctx.lock.acquire()
      ctx.tasks.delete(i)
    finally:
      ctx.lock.release()

  if ctx.tasks.len > 0:
    poll()


proc load(T: type VerifiedProxyConf, configJson: string): T {.raises: [CatchableError, ValueError]}=
  let jsonNode = parseJson($configJson)

  let
    eth2Network = some(jsonNode.getOrDefault("Eth2Network").getStr("mainnet"))
    trustedBlockRoot = 
      if jsonNode.contains("TrustedBlockRoot"):
        Eth2Digest.fromHex(jsonNode["TrustedBlockRoot"].getStr())
      else:
        raise newException(ValueError, "`TrustedBlockRoot` not specified in JSON config")
    backendUrl = 
      if jsonNode.contains("BackendUrl"):
        parseCmdArg(Web3Url, jsonNode["BackendUrl"].getStr())
      else:
        raise newException(ValueError, "`BackendUrl` not specified in JSON config")
    logLevel = jsonNode.getOrDefault("LogLevel").getStr("INFO")
    defaultListenAddress = (static parseIpAddress("0.0.0.0"))

  return VerifiedProxyConf(
    listenAddress: none(IpAddress),
    eth2Network: eth2Network,
    trustedBlockRoot: trustedBlockRoot,
    backendUrl: backendUrl,
    logLevel: logLevel,
    maxPeers: 160,
    nat: NatConfig(hasExtIp: false, nat: NatAny),
    logStdout: StdoutLogKind.Auto,
    dataDirFlag: none(OutDir),
    tcpPort: Port(defaultEth2TcpPort),
    udpPort: Port(defaultEth2TcpPort),
    agentString: "nimbus",
    discv5Enabled: true,
  )

proc run(ctx: ptr Context, configJson: string) {.async: (raises: [ValueError, CancelledError, CatchableError]).} =
  try:
    initLib()
  except Exception as err:
    raise newException(CancelledError, err.msg)

  let config = VerifiedProxyConf.load($configJson)

  echo $config

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
    jsonRpcClient = JsonRpcClient.init(config.backendUrl)

 # the backend only needs the url to connect to
  engine.backend = jsonRpcClient.getEthApiBackend()

  # inject the frontend into c context
  ctx.frontend = engine.frontend

  # start frontend and backend
  var status = await jsonRpcClient.start()
  if status.isErr():
    raise newException(ValueError, status.error)
  # FIXME: throws illegal storage access SEGFAULT when used as a library but not when run as a nim program.
  # await startLightClient(config, engine)

proc startVerifProxy(ctx: ptr Context, configJson: cstring, cb: CallBackProc) {.exported.} =
  try:
    waitFor run(ctx, $configJson)
  except:
    quit(QuitFailure)

proc stopVerifProxy*(ctx: ptr Context) {.exported.} =
  ctx.lock.acquire()
  ctx.stop = true
  ctx.lock.release()

# C-callable: downloads a page and returns a heap-allocated C string.
proc nonBusySleep(ctx: ptr Context, secs: cint, cb: CallBackProc) {.exported.} =
  let task = createTask(cb)

  try:
    ctx.lock.acquire()
    ctx.tasks.add(task)
  finally:
    ctx.lock.release()

  let fut = sleepAsync((secs).seconds)

  fut.addCallback proc (_: pointer) {.gcsafe.} =
    try:
      ctx.lock.acquire()
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
    finally:
      ctx.lock.release()
