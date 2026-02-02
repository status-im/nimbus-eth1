# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  json_rpc/rpcserver,
  stew/byteutils,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ./rpc_types

export rpc_types # tasty sandwich

type PongResponse* = object
  enrSeq: uint64
  recipientIP: string
  recipientPort: uint16

PongResponse.useDefaultSerializationIn EthJson

proc installDiscoveryApiHandlers*(rpcServer: RpcServer, d: discv5_protocol.Protocol) =
  ## Discovery v5 JSON-RPC API such as defined here:
  ## https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc

  rpcServer.rpc(EthJson):
    proc discv5_nodeInfo(): NodeInfo =
      return d.routingTable.getNodeInfo()

    proc discv5_updateNodeInfo(kvPairs: seq[(string, string)]): NodeInfo =
      # TODO: Not according to spec, as spec only allows socket address.
      # portal-specs PR has been created with suggested change as is here.
      let enrFields = kvPairs.map(
        proc(n: (string, string)): (string, seq[byte]) {.raises: [ValueError].} =
          (n[0], hexToSeqByte(n[1]))
      )
      let updated = d.updateRecord(enrFields)
      if updated.isErr():
        raise newException(ValueError, $updated.error)

      return d.routingTable.getNodeInfo()

    proc discv5_routingTableInfo(): RoutingTableInfo =
      return getRoutingTableInfo(d.routingTable)

    proc discv5_addEnr(enr: Record): bool =
      let node = Node.fromRecord(enr)
      let res = d.addNode(node)
      if res:
        d.routingTable.setJustSeen(node)
      return res

    proc discv5_addEnrs(enrs: seq[Record]): bool =
      # Note: unspecified RPC, but useful for our local testnet test
      # TODO: We could also adjust the API of addNode & fromRecord to accept a seen
      # parameter, but perhaps only if that makes sense on other locations in
      # discv5/portal that are not testing/debug related.
      for enr in enrs:
        let node = Node.fromRecord(enr)
        if d.addNode(node):
          d.routingTable.setJustSeen(node)

      return true

    proc discv5_getEnr(nodeId: NodeId): Record =
      let node = d.getNode(nodeId)
      if node.isSome():
        return node.get().record
      else:
        raise newException(ValueError, "Record not in local routing table.")

    proc discv5_deleteEnr(nodeId: NodeId): bool =
      # TODO: Adjust `removeNode` to accept NodeId as param and to return bool.
      let node = d.getNode(nodeId)
      if node.isSome():
        d.routingTable.removeNode(node.get())
        return true
      else:
        raise newException(ValueError, "Record not in local routing table.")

    proc discv5_lookupEnr(nodeId: NodeId): Record =
      let lookup = await d.resolve(nodeId)
      if lookup.isSome():
        return lookup.get().record
      else:
        raise newException(ValueError, "Record not found in DHT lookup.")

    proc discv5_ping(enr: Record): PongResponse =
      let
        node = toNodeWithAddress(enr)
        pong = await d.ping(node)

      if pong.isErr():
        raise newException(ValueError, $pong.error)
      else:
        let p = pong.get()
        return PongResponse(enrSeq: p.enrSeq, recipientIP: $p.ip, recipientPort: p.port)

    proc discv5_findNode(enr: Record, distances: seq[uint16]): seq[Record] =
      let
        node = toNodeWithAddress(enr)
        nodes = await d.findNode(node, distances)
      if nodes.isErr():
        raise newException(ValueError, $nodes.error)
      else:
        return nodes.get().map(
            proc(n: Node): Record =
              n.record
          )

    proc discv5_talkReq(enr: Record, protocol, payload: string): string =
      let
        node = toNodeWithAddress(enr)
        talkresp = await d.talkReq(node, hexToSeqByte(protocol), hexToSeqByte(payload))
      if talkresp.isErr():
        raise newException(ValueError, $talkresp.error)
      else:
        return talkresp.get().toHex()

    proc discv5_recursiveFindNodes(nodeId: NodeId): seq[Record] =
      let discovered = await d.lookup(nodeId)
      return discovered.map(
        proc(n: Node): Record =
          n.record
      )
