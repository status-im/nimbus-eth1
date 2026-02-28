# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  std/[net, importutils, random],
  chronos,
  chronicles,
  results,
  metrics,
  eth/common/base_rlp,
  eth/enode/enode_utils,
  ./discoveryv5,
  ./discoveryv4,
  ./bootnodes

export
  discoveryv4.NodeId,
  discoveryv4.Node,
  discoveryv4.ENode

logScope:
  topics = "p2p"

type
  DiscV4 = discoveryv4.DiscoveryV4
  DiscV5 = discoveryv5.Protocol

  NodeV4 = discoveryv4.Node
  NodeV5 = discoveryv5.Node

  AddressV4 = discoveryv4.Address
  AddressV5 = discoveryv5.Address

  CompatibleForkIdProc* = proc(id: ForkId): bool {.noSideEffect, raises: [].}

  Eth1Discovery* = ref object
    discv4: DiscV4
    discv5: DiscV5
    compatibleForkId: CompatibleForkIdProc

declareCounter disc_incoming_packets, "Number of incoming packets on discovery port", labels = ["type"]
declareCounter discv5_nodes_discovered, "Number of nodes discovered via discv5", labels = ["type"]
declareCounter discv4_nodes_discovered, "Number of nodes discovered via discv4"

#------------------------------------------------------------------------------
# Private functions
#------------------------------------------------------------------------------

func to(raddr: TransportAddress, _: type AddressV4): AddressV4 =
  AddressV4(
    ip: raddr.toIpAddress(),
    udpPort: raddr.port,
    tcpPort: raddr.port
  )

func to(raddr: TransportAddress, _: type AddressV5): AddressV5 =
  AddressV5(ip: raddr.toIpAddress(), port: raddr.port)

func to(node: NodeV5, _: type NodeV4): ENodeResult[NodeV4] =
  let v4 = NodeV4(
    id: node.id,
    node: ?ENode.fromEnr(node.record),
    fromDiscv5: true,
  )
  ok(v4)

proc processClient(
    transp: DatagramTransport, raddr: TransportAddress
): Future[void] {.async: (raises: []).} =
  var proto = getUserData[Eth1Discovery](transp)
  let buf =
    try:
      transp.getMessage()
    except TransportOsError as e:
      # This is likely to be local network connection issues.
      warn "Transport getMessage", exception = e.name, msg = e.msg
      return
    except TransportError as exc:
      debug "getMessage error", msg = exc.msg
      return

  let
    addrv4 = raddr.to(AddressV4)
    discv4 = proto.discv4.receive(addrv4, buf)

  if discv4.isErr:
    # unhandled buf will be handled by discv5
    let addrv5 = raddr.to(AddressV5)
    let res = proto.discv5.receiveV5(addrv5, buf)
    if res.isErr:
      debug "Discovery receive error", discv4=discv4.error, discv5=res.error, address=addrv5
      disc_incoming_packets.inc(labelValues = ["spam"])
    else:
      disc_incoming_packets.inc(labelValues = ["discv5"])

  else:
    disc_incoming_packets.inc(labelValues = ["discv4"])

func eligibleNode(proto: Eth1Discovery, rec: Record): bool =
  # Filter out non `eth` node
  let
    bytes = rec.tryGet("eth", seq[byte]).valueOr:
      return false

  if proto.compatibleForkId.isNil:
    # Allow all `eth` node to pass if there is no filter
    return true

  let
    ethValue =
      try:
        rlp.decode(bytes, array[1, ForkId])
      except RlpError:
        return false
    forkId  = ethValue[0]

  proto.compatibleForkId(forkId)

#------------------------------------------------------------------------------
# Public functions
#------------------------------------------------------------------------------

proc new*(
    _: type Eth1Discovery,
    privKey: PrivateKey,
    enrIp: Opt[IpAddress],
    enrTcpPort, enrUdpPort: Opt[Port],
    bootstrapNodes: BootstrapNodes,
    bindPort: Port,
    bindIp = IPv6_any(),
    rng = newRng(),
    compatibleForkId = CompatibleForkIdProc(nil)
): Eth1Discovery =
  let address = enode.Address(
      ip: enrIp.valueOr(bindIp),
      tcpPort: enrTcpPort.valueOr(bindPort),
      udpPort: enrUdpPort.valueOr(bindPort),
    )
  Eth1Discovery(
    discv4: discoveryv4.newDiscoveryV4(
      privKey = privKey,
      address = address,
      bootstrapNodes = bootstrapNodes.enodes,
      bindPort = bindPort,
      bindIp = bindIp,
      rng = rng
    ),
    discv5: discoveryv5.newProtocol(
      privKey = privKey,
      enrIp = enrIp,
      enrTcpPort = enrTcpPort,
      enrUdpPort = enrUdpPort,
      enrQuicPort = Opt.none(Port),
      bootstrapRecords = bootstrapNodes.enrs,
      bindPort = bindPort,
      bindIp = Opt.some(bindIp),
      enrAutoUpdate = true,
      rng = rng
    ),
    compatibleForkId: compatibleForkId,
  )

proc open*(
    proto: Eth1Discovery, enableDiscV4: bool, enableDiscV5: bool
) {.raises: [TransportOsError].} =
  # TODO: allow binding to both IPv4 and IPv6

  if not (enableDiscV4 or enableDiscV5):
    return

  privateAccess(DiscV4)
  privateAccess(DiscV5)

  info "Starting discovery node",
    node = proto.discv4.localNode,
    bindAddress = proto.discv4.address,
    discV4 = enableDiscV4,
    discV5 = enableDiscV5

  if enableDiscV4 and not enableDiscV5:
    proto.discv4.open()
    proto.discv5 = nil
    return

  if enableDiscV5 and not enableDiscV4:
    proto.discv5.open()
    proto.discv4 = nil
    proto.discv5.seedTable()
    return

  # Both DiscV4 and DiscV5 share the same transport
  # Unhandled data from DiscV4 will be handled by DiscV5
  let ta = initTAddress(proto.discv4.bindIp, proto.discv4.bindPort)
  proto.discv4.transp = newDatagramTransport(processClient, udata = proto, local = ta)
  proto.discv5.transp = proto.discv4.transp
  proto.discv5.seedTable()

proc start*(proto: Eth1Discovery) {.async: (raises: [CancelledError]).} =
  if proto.discv4.isNil.not:
    await proto.discv4.bootstrap()
  if proto.discv5.isNil.not:
    proto.discv5.start()

proc lookupRandomNode*(proto: Eth1Discovery, queue: AsyncQueue[NodeV4]) {.async: (raises: [CancelledError]).} =
  if proto.discv4.isNil.not:
    let nodes = await proto.discv4.lookupRandom()
    for node in nodes:
      discv4_nodes_discovered.inc()
      await queue.addLast(node)

  if proto.discv5.isNil.not:
    let nodes = await proto.discv5.queryRandom()
    for node in nodes:
      discv5_nodes_discovered.inc()
      if not proto.eligibleNode(node.record):
        continue
      let v4 = node.to(NodeV4).valueOr:
        continue
      discv5_nodes_discovered.inc(labelValues = ["eligible"])
      await queue.addLast(v4)

proc getRandomBootnode*(proto: Eth1Discovery): Opt[NodeV4] =
  if proto.discv4.isNil.not:
    if proto.discv4.bootstrapNodes.len != 0:
      return Opt.some(proto.discv4.bootstrapNodes.sample())

  if proto.discv5.isNil.not:
    if proto.discv5.bootstrapRecords.len != 0:
      let
        rec = proto.discv5.bootstrapRecords.sample()
        enode = ENode.fromEnr(rec).valueOr:
          return Opt.none(NodeV4)
      return Opt.some(newNode(enode))

func updateForkId*(proto: Eth1Discovery, forkId: ForkId) =
  # https://github.com/ethereum/devp2p/blob/bc76b9809a30e6dc5c8dcda996273f0f9bcf7108/enr-entries/eth.md
  if proto.discv5.isNil.not:
    let
      list = [forkId]
      bytes = rlp.encode(list)
      kv = ("eth", bytes)
    proto.discv5.updateRecord([kv]).isOkOr:
      return

proc closeWait*(proto: Eth1Discovery) {.async: (raises: []).} =
  privateAccess(DiscV4)
  if proto.discv4.isNil.not and proto.discv5.isNil:
    if proto.discv4.transp.isNil.not:
      await noCancel(proto.discv4.transp.closeWait())
    return

  # Because UDP transport is shared between DiscV4 and DiscV5,
  # no need for DiscV4 to close it anymore if both enabled.
  # It will be closed by DiscV5.
  if proto.discv5.isNil.not:
    await proto.discv5.closeWait()
