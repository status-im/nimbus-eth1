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
  std/net,
  chronos,
  chronicles,
  eth/common/[base_rlp, keys],
  eth/enode/[enode, enode_utils],
  eth/p2p/discoveryv5/[protocol as discv5_protocol],
  ./p2p_node,
  ./bootnodes

export p2p_node.NodeId, p2p_node.Node, p2p_node.newNode, enode.ENode

logScope:
  topics = "p2p"

type
  CompatibleForkIdProc* = proc(id: ForkId): bool {.noSideEffect, raises: [].}

  Eth1Discovery* = ref object
    discv5: discv5_protocol.Protocol
    compatibleForkId: CompatibleForkIdProc

#------------------------------------------------------------------------------
# Private functions
#------------------------------------------------------------------------------

func eligibleNode(proto: Eth1Discovery, rec: enr.Record): bool =
  # Filter out non `eth` node
  let bytes = rec.tryGet("eth", seq[byte]).valueOr:
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
    forkId = ethValue[0]

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
    compatibleForkId = CompatibleForkIdProc(nil),
): Eth1Discovery =
  Eth1Discovery(
    discv5: discv5_protocol.newProtocol(
      privKey = privKey,
      enrIp = enrIp,
      enrTcpPort = enrTcpPort,
      enrUdpPort = enrUdpPort,
      enrQuicPort = Opt.none(Port),
      bootstrapRecords = bootstrapNodes.enrs,
      bindPort = bindPort,
      bindIp = Opt.some(bindIp),
      enrAutoUpdate = true,
      rng = rng,
    ),
    compatibleForkId: compatibleForkId,
  )

proc open*(proto: Eth1Discovery) {.raises: [TransportOsError].} =
  proto.discv5.open()

proc start*(proto: Eth1Discovery) =
  proto.discv5.start()

proc lookupRandomNode*(
    proto: Eth1Discovery, queue: AsyncQueue[p2p_node.Node]
) {.async: (raises: [CancelledError]).} =
  let discv5Nodes = await proto.discv5.queryRandom()
  for discv5Node in discv5Nodes:
    if not proto.eligibleNode(discv5Node.record):
      continue
    let enode = ENode.fromEnr(discv5Node.record).valueOr:
      continue
    await queue.addLast(newNode(enode))

func getEnr*(proto: Eth1Discovery): Opt[string] =
  ## Get the ENR URI string of the local node from DiscoveryV5.
  if proto.isNil: return Opt.none(string)
  Opt.some(proto.discv5.getRecord().toURI())

func updateForkId*(proto: Eth1Discovery, forkId: ForkId) =
  # https://github.com/ethereum/devp2p/blob/bc76b9809a30e6dc5c8dcda996273f0f9bcf7108/enr-entries/eth.md
  let
    list = [forkId]
    bytes = rlp.encode(list)
    kv = ("eth", bytes)
  proto.discv5.updateRecord([kv]).isOkOr:
    return

proc closeWait*(proto: Eth1Discovery) {.async: (raises: []).} =
  await proto.discv5.closeWait()
