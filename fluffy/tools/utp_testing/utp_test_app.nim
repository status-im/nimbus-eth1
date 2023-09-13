# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[hashes, tables],
  chronos, chronicles, confutils,
  confutils/std/net as confNet,
  stew/[byteutils, endians2],
  stew/shims/net,
  json_rpc/servers/httpserver,
  eth/p2p/discoveryv5/protocol,
  eth/p2p/discoveryv5/enr,
  eth/utp/[utp_discv5_protocol, utp_router],
  eth/keys,
  ../../rpc/rpc_discovery_api

const
  defaultListenAddress* = (static ValidIpAddress.init("127.0.0.1"))

type AppConf* = object
  rpcPort* {.
    defaultValue: 7041
    desc: "Json rpc port"
    name: "rpc-port" .}: Port

  udpPort* {.
    defaultValue: 7042
    desc: "UDP listening port"
    name: "udp-port" .}: Port

  udpListenAddress* {.
    defaultValue: defaultListenAddress
    desc: "UDP listening address"
    name: "udp-listen-address" .}: ValidIpAddress

  rpcListenAddress* {.
    defaultValue: defaultListenAddress
    desc: "RPC listening address"
    name: "rpc-listen-address" .}: ValidIpAddress

proc `%`*(value: enr.Record): JsonNode =
  newJString(value.toURI())

proc fromJson*(n: JsonNode, argName: string, result: var Record)
    {.raises: [ValueError].} =
  n.kind.expect(JString, argName)
  echo "ENr looks " & n.getStr()

  if not fromURI(result, n.getStr()):
    raise newException(ValueError, "Invalid ENR")

type SKey = object
  id: uint16
  nodeId: NodeId

proc `%`*(value: SKey): JsonNode =
  let hex = value.nodeId.toBytesBE().toHex()
  let numId = value.id.toBytesBE().toHex()
  let finalStr = hex & numId
  newJString(finalStr)

proc fromJson*(n: JsonNode, argName: string, result: var SKey)
    {.raises: [ValueError].} =
  n.kind.expect(JString, argName)
  let str = n.getStr()
  let strLen = len(str)
  if (strLen >= 64):
    let nodeIdStr = str.substr(0, 63)
    let connIdStr = str.substr(64)
    let nodeId = NodeId.fromHex(nodeIdStr)
    let connId = uint16.fromBytesBE(connIdStr.hexToSeqByte())
    result = SKey(nodeId: nodeId, id: connId)
  else:
    raise newException(ValueError, "Too short string")

proc hash(x: SKey): Hash =
  var h = 0
  h = h !& x.id.hash
  h = h !& x.nodeId.hash
  !$h

func toSKey(k: UtpSocketKey[NodeAddress]): SKey =
  SKey(id: k.rcvId, nodeId: k.remoteAddress.nodeId)

proc installUtpHandlers(
  srv: RpcHttpServer,
  d: protocol.Protocol,
  s: UtpDiscv5Protocol,
  t: ref Table[SKey, UtpSocket[NodeAddress]]) {.raises: [CatchableError].} =

  srv.rpc("utp_connect") do(r: enr.Record) -> SKey:
    let
      nodeRes = newNode(r)

    if nodeRes.isOk():
      let node = nodeRes.get()
      let nodeAddress = NodeAddress.init(node).unsafeGet()
      discard d.addNode(node)
      let connResult = await s.connectTo(nodeAddress)
      if (connresult.isOk()):
        let socket = connresult.get()
        let sKey = socket.socketKey.toSKey()
        t[sKey] = socket
        return sKey
      else:
        raise newException(ValueError, "Connection to node Failed.")
    else:
      raise newException(ValueError, "Bad enr")

  srv.rpc("utp_write") do(k: SKey, b: string) -> bool:
    let sock = t.getOrDefault(k)
    let bytes = hexToSeqByte(b)
    if sock != nil:
      # TODO consider doing it async to avoid json-rpc timeouts in case of large writes
      let res = await sock.write(bytes)
      if res.isOk():
        return true
      else:
        # TODO return correct errors instead of just true/false
        return false
    else:
      raise newException(ValueError, "Socket with provided key is missing")

  srv.rpc("utp_get_connections") do() -> seq[SKey]:
    var keys = newSeq[SKey]()

    for k in t.keys:
      keys.add(k)

    return keys

  srv.rpc("utp_read") do(k: SKey, n: int) -> string:
    let sock = t.getOrDefault(k)
    if sock != nil:
      let res = await sock.read(n)
      let asHex = res.toHex()
      return asHex
    else:
      raise newException(ValueError, "Socket with provided key is missing")

  srv.rpc("utp_close") do(k: SKey) -> bool:
    let sock = t.getOrDefault(k)
    if sock != nil:
      await sock.closeWait()
      return true
    else:
      raise newException(ValueError, "Socket with provided key is missing")

proc buildAcceptConnection(t: ref Table[SKey, UtpSocket[NodeAddress]]): AcceptConnectionCallback[NodeAddress] =
  return (
    proc (server: UtpRouter[NodeAddress], client: UtpSocket[NodeAddress]): Future[void] =
      let fut = newFuture[void]()
      let key = client.socketKey.toSKey()
      t[key] = client
      fut.complete()
      return fut
  )

when isMainModule:
  var table = newTable[SKey, UtpSocket[NodeAddress]]()

  let rng = newRng()

  {.pop.}
  let conf = AppConf.load()
  {.push raises: [].}

  let
    protName = "test-utp".toBytes()
    la = initTAddress(conf.rpcListenAddress, conf.rpcPort)
    key = PrivateKey.random(rng[])
    discAddress = conf.udpListenAddress
    srv = newRpcHttpServer(@[la], RpcRouter.init())

  srv.start()

  let d = newProtocol(
    key,
    some(discAddress), none(Port), some(conf.udpPort),
    bootstrapRecords = @[],
    bindIp = discAddress, bindPort = conf.udpPort,
    enrAutoUpdate = true,
    rng = rng)

  d.open()

  let
    cfg = SocketConfig.init(incomingSocketReceiveTimeout = none[Duration]())
    utp = UtpDiscv5Protocol.new(d, protName, buildAcceptConnection(table), socketConfig = cfg)

  # needed for some of the discovery api: nodeInfo, setEnr, ping
  srv.installDiscoveryApiHandlers(d)

  srv.installUtpHandlers(d, utp, table)

  runForever()
