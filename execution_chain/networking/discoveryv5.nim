# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  std/[importutils, tables],
  metrics,
  chronicles,
  eth/p2p/discoveryv5/enr,
  eth/p2p/discoveryv5/encoding,
  eth/p2p/discoveryv5/sessions,
  eth/p2p/discoveryv5/protocol {.all.}

export
  Protocol, Node, Address, enr, newProtocol, open, close, seedTable, start, queryRandom, closeWait
  
proc receiveV5*(d: Protocol, a: Address, packet: openArray[byte]): Result[void, cstring] =
  privateAccess(Protocol)
  privateAccess(PendingRequest)
  discv5_network_bytes.inc(packet.len.int64, labelValues = [$Direction.In])

  let packet = ?d.codec.decodePacket(a, packet)

  case packet.flag
  of OrdinaryMessage:
    if d.isBanned(packet.srcId):
      trace "Ignoring received OrdinaryMessage from banned node", nodeId = packet.srcId
      return ok()

    if packet.messageOpt.isSome():
      let message = packet.messageOpt.get()
      trace "Received message packet", srcId = packet.srcId, address = a,
        kind = message.kind
      d.handleMessage(packet.srcId, a, message)
    else:
      trace "Not decryptable message packet received",
        srcId = packet.srcId, address = a
      d.sendWhoareyou(packet.srcId, a, packet.requestNonce,
        d.getNode(packet.srcId))

  of Flag.Whoareyou:
    trace "Received whoareyou packet", address = a
    var pr: PendingRequest
    if d.pendingRequests.take(packet.whoareyou.requestNonce, pr):
      let toNode = pr.node
      # This is a node we previously contacted and thus must have an address.
      doAssert(toNode.address.isSome())
      let address = toNode.address.get()
      let data = encodeHandshakePacket(d.rng[], d.codec, toNode.id,
        address, pr.message, packet.whoareyou, toNode.pubkey)

      # Finished setting up the session on our side, so store the ENR of the
      # peer in the session cache.
      d.codec.sessions.setEnr(toNode.id, address, toNode.record)

      trace "Send handshake message packet", dstId = toNode.id, address
      d.send(toNode, data)
    else:
      debug "Timed out or unrequested whoareyou packet", address = a
  of HandshakeMessage:
    if d.isBanned(packet.srcIdHs):
      trace "Ignoring received HandshakeMessage from banned node", nodeId = packet.srcIdHs
      return ok()

    trace "Received handshake message packet", srcId = packet.srcIdHs,
      address = a, kind = packet.message.kind

    # For a handshake message it is possible that we received an newer ENR.
    # In that case we can add/update it to the routing table.
    if packet.node.isSome():
      let node = packet.node.get()
      # Lets not add nodes without correct IP in the ENR to the routing table.
      # The ENR could contain bogus IPs and although they would get removed
      # on the next revalidation, one could spam these as the handshake
      # message occurs on (first) incoming messages.
      if node.address.isSome() and a == node.address.get():
        if d.addNode(node):
          trace "Added new node to routing table after handshake", node

      # Received an ENR in the handshake, add it to the session that was just
      # created in the session cache.
      d.codec.sessions.setEnr(packet.srcIdHs, a, node.record)
    else:
      # Did not receive an ENR in the handshake, this means that the ENR used
      # is up to date. Get it from the routing table which should normally
      # be there unless the request was started manually (E.g. from a JSON-RPC call).
      let node = d.getNode(packet.srcIdHs)
      if node.isSome():
        d.codec.sessions.setEnr(packet.srcIdHs, a, node.value().record)

    # The handling of the message needs to be done after adding the ENR.
    d.handleMessage(packet.srcIdHs, a, packet.message, packet.node)

  ok()
