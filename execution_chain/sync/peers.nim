# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[hashes, tables],
  chronicles,
  chronos,
  eth/p2p,
  eth/p2p/peer_pool,
  ./protocol

# Currently, this module only handles static peers
# but we can extend it to handles trusted peers as well
# or bootnodes

type
  ReconnectState = ref object
    node: Node
    retryCount: int
    connected: bool

  PMState = enum
    Starting, Running, Stopping, Stopped

  PeerManagerRef* = ref object
    state: PMState
    pool: PeerPool
    maxRetryCount: int # zero == infinite
    retryInterval: int # in seconds
    reconnectStates: Table[Node,ReconnectState]
    reconnectFut: Future[void]

logScope:
  topics = "PeerManagerRef"

template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

proc setConnected(pm: PeerManagerRef, peer: Peer, connected: bool) =
  if pm.reconnectStates.hasKey(peer.remote):
    noKeyError("setConnected"):
      pm.reconnectStates[peer.remote].connected = connected
  else:
    # Peer was not registered a static, so ignore it
    trace "Could not update non-static peer", peer, connected

proc needReconnect(pm: PeerManagerRef): bool =
  for n in pm.reconnectStates.values:
    if not n.connected:
      return true

proc reconnect(pm: PeerManagerRef) {.async, gcsafe.} =
  for n in pm.reconnectStates.values:
    if not n.connected and pm.state == Running:
      if n.retryCount < pm.maxRetryCount or pm.maxRetryCount == 0:
        trace "Reconnecting to", remote=n.node.node
        await pm.pool.connectToNode(n.node)
        inc n.retryCount
      elif n.retryCount == pm.maxRetryCount:
        trace "Exceed max retry count, give up reconnecting", remote=n.node.node
        inc n.retryCount

proc runReconnectLoop(pm: PeerManagerRef) {.async, gcsafe.} =
  while pm.state == Running:
    if pm.needReconnect:
      await pm.reconnect
    else:
      pm.state = Stopping
      break
    await sleepAsync(pm.retryInterval.seconds)

proc setupManager(pm: PeerManagerRef, enodes: openArray[ENode]) =
  var po: PeerObserver
  po.onPeerConnected = proc(peer: Peer) {.gcsafe.} =
    trace "Peer connected", remote=peer.remote.node
    pm.setConnected(peer, true)

  po.onPeerDisconnected = proc(peer: Peer) {.gcsafe.} =
    trace "Peer disconnected", remote=peer.remote.node
    pm.setConnected(peer, false)
    if pm.state notin {Running, Stopped}:
      pm.state = Running
      pm.reconnectFut = pm.runReconnectLoop()

  po.setProtocol eth
  pm.pool.addObserver(pm, po)

  for enode in enodes:
    let state = ReconnectState(
      node: newNode(enode),
      retryCount: 0,
      connected: false
    )
    pm.reconnectStates[state.node] = state

proc new*(_: type PeerManagerRef,
          pool: PeerPool,
          retryInterval: int,
          maxRetryCount: int,
          enodes: openArray[ENode]): PeerManagerRef =
  result = PeerManagerRef(
    pool: pool,
    state: Starting,
    maxRetryCount: max(0, maxRetryCount),
    retryInterval: max(5, retryInterval)
  )
  result.setupManager(enodes)

proc start*(pm: PeerManagerRef) =
  if pm.state notin {Stopped, Running} and pm.needReconnect:
    pm.state = Running
    pm.reconnectFut = pm.runReconnectLoop()
    info "Reconnecting to static peers"

proc stop*(pm: PeerManagerRef) {.async.} =
  if pm.state notin {Stopped, Stopping}:
    pm.state = Stopped
    await pm.reconnectFut.cancelAndWait()
    info "Peer manager stopped"
