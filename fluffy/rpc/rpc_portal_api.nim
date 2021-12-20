# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/sequtils,
  json_rpc/[rpcproxy, rpcserver], stew/byteutils,
  eth/p2p/discoveryv5/nodes_verification,
  ../network/wire/portal_protocol,
  ./rpc_types

export rpcserver

# Note:
# Using a string for the network parameter will give an error in the rpc macro:
# Error: Invalid node kind nnkInfix for macros.`$`
# Using a static string works but some sandwich problem seems to be happening,
# as the proc becomes generic, where the rpc macro from router.nim can no longer
# be found, which is why we export rpcserver which should export router.
proc installPortalApiHandlers*(
    rpcServer: RpcServer|RpcProxy, p: PortalProtocol, network: static string)
    {.raises: [Defect, CatchableError].} =
  ## Portal routing table and portal wire json-rpc API is not yet defined but
  ## will look something similar as what exists here now:
  ## https://github.com/ethereum/portal-network-specs/pull/88

  rpcServer.rpc("portal_" & network & "_nodeInfo") do() -> NodeInfo:
    return p.routingTable.getNodeInfo()

  rpcServer.rpc("portal_" & network & "_routingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(p.routingTable)

  rpcServer.rpc("portal_" & network & "_lookupEnr") do(nodeId: NodeId) -> Record:
    let lookup = await p.resolve(nodeId)
    if lookup.isSome():
      return lookup.get().record
    else:
      raise newException(ValueError, "Record not found in DHT lookup.")

  rpcServer.rpc("portal_" & network & "_ping") do(
      enr: Record) -> tuple[seqNum: uint64, customPayload: string]:
    let
      node = toNodeWithAddress(enr)
      pong = await p.ping(node)

    if pong.isErr():
      raise newException(ValueError, $pong.error)
    else:
      let p = pong.get()
      return (p.enrSeq, p.customPayload.asSeq().toHex())

  rpcServer.rpc("portal_" & network & "_findNodes") do(
      enr: Record, distances: seq[uint16]) -> seq[Record]:
    let
      node = toNodeWithAddress(enr)
      nodes = await p.findNodesVerified(node, distances)
    if nodes.isErr():
      raise newException(ValueError, $nodes.error)
    else:
      return nodes.get().map(proc(n: Node): Record = n.record)

  # TODO: This returns null values for the `none`s. Not sure what it should be
  # according to spec, no k:v pair at all?
  # Note: Would it not be nice to have a call that resturns either content or
  # ENRs, and that the connection id is used in the background instead of this
  # "raw" `findContent` call.
  rpcServer.rpc("portal_" & network & "_findContent") do(
      enr: Record, contentKey: string) -> tuple[
        connectionId: Option[string],
        content: Option[string],
        enrs: Option[seq[Record]]]:
    let
      node = toNodeWithAddress(enr)
      content = await p.findContent(
        node, ByteList.init(hexToSeqByte(contentKey)))

    if content.isErr():
      raise newException(ValueError, $content.error)
    else:
      let contentMessage = content.get()
      case contentMessage.contentMessageType:
      of connectionIdType:
        return (
          some("0x" & contentMessage.connectionId.toHex()),
          none(string),
          none(seq[Record]))
      of contentType:
        return (
          none(string),
          some("0x" & contentMessage.content.asSeq().toHex()),
          none(seq[Record]))
      of enrsType:
        let records = recordsFromBytes(contentMessage.enrs)
        if records.isErr():
          raise newException(ValueError, $records.error)
        else:
          return (
            none(string),
            none(string),
            # Note: Could also pass not verified nodes
            some(verifyNodesRecords(
              records.get(), node, enrsResultLimit).map(
                proc(n: Node): Record = n.record)))

  rpcServer.rpc("portal_" & network & "_recursiveFindNodes") do() -> seq[Record]:
    let discovered = await p.queryRandom()
    return discovered.map(proc(n: Node): Record = n.record)
