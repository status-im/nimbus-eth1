# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Tests for the two mechanisms that keep the number of open RLPx connections
## bounded:
##
## * incoming connections are refused with `TooManyPeers` once the pool holds
##   `--max-peers` peers, and
## * a connection whose remote end has gone away without closing the socket is
##   reaped by the liveness monitor.

{.used.}

import
  unittest2,
  testutils,
  chronos,
  ../../execution_chain/networking/p2p,
  ./stubloglevel,
  ./p2p_test_helper

proc waitForPeers(
    node: EthereumNode, want: int, timeout: Duration
): Future[bool] {.async: (raises: [CancelledError]).} =
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    if node.numPeers == want:
      return true
    await sleepAsync(50.milliseconds)
  node.numPeers == want

proc waitForRefresh(
    node: EthereumNode, after: Moment, timeout: Duration
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Wait until some peer of `node` has received a message after `after`
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    for peer in node.peers:
      if peer.lastReceived > after:
        return true
    await sleepAsync(50.milliseconds)
  false

func monitorDone(peer: Peer): bool =
  peer.keepAlive.isNil or peer.keepAlive.finished

proc waitForMonitorExit(
    peer: Peer, timeout: Duration
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## `disconnect` cancels the monitor with `cancelSoon`, which is deferred, so
  ## the exit has to be polled for rather than asserted immediately.
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    if peer.monitorDone:
      return true
    await sleepAsync(50.milliseconds)
  peer.monitorDone

proc waitForClose(
    peer: Peer, timeout: Duration
): Future[bool] {.async: (raises: [CancelledError]).} =
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    if peer.transport.closed:
      return true
    await sleepAsync(50.milliseconds)
  peer.transport.closed

proc onlyPeer(node: EthereumNode): Peer =
  ## The node's single pooled peer, captured so the socket can still be
  ## inspected after the pool has dropped it.
  for peer in node.peers:
    return peer
  nil

procSuite "Peer limits":

  asyncTest "Incoming connections are refused once max-peers is reached":
    var
      listener = newTestEnv(maxPeers = 1)
      first = newTestEnv()
      second = newTestEnv()

    listener.node.startListening()

    let firstRes = await first.node.rlpxConnect(newNode(listener.node.toENode()))
    check firstRes.isOk()
    check await listener.node.waitForPeers(1, 5.seconds)

    # The pool is full now, so the listener must tell the second dialer to go
    # away instead of holding the socket open forever
    let secondRes = await second.node.rlpxConnect(newNode(listener.node.toENode()))
    check secondRes.isErr()
    if secondRes.isErr():
      check secondRes.error == TooManyPeersError
    check listener.node.numPeers == 1

    await second.close()
    await first.close()
    await listener.close()

  asyncTest "Silent peers are reaped by the liveness monitor":
    ## The reaper exists to stop sockets accumulating, so leaving the pool is
    ## not the assertion that matters - the fd going away is. Checks the whole
    ## chain: pool entry dropped, monitor exited, our socket closed, and the
    ## remote end seeing the FIN.
    var
      listener = newTestEnv()
      dialer = newTestEnv()

    listener.node.startListening()

    let connRes = await dialer.node.rlpxConnect(newNode(listener.node.toENode()))
    check connRes.isOk()
    let dialerPeer = connRes.get()
    check await listener.node.waitForPeers(1, 5.seconds)

    let listenerPeer = listener.node.onlyPeer()
    check not listenerPeer.isNil
    check not listenerPeer.transport.closed
    check not listenerPeer.monitorDone

    # Pretend nothing has arrived from the peer for longer than the idle
    # timeout - this is what a connection looks like when the remote end
    # vanished without sending a FIN
    listenerPeer.lastReceived = Moment.now() - 61.seconds

    check await listener.node.waitForPeers(0, 15.seconds)

    # The socket, not just the bookkeeping. Without the close the fd would sit
    # ESTABLISHED forever with nothing left to reap it.
    check await listenerPeer.waitForClose(5.seconds)
    # ...and the monitor must not keep ticking on a peer it has given up on.
    check await listenerPeer.waitForMonitorExit(5.seconds)
    # A real FIN went out on the wire, rather than only local state changing.
    check await dialerPeer.waitForClose(10.seconds)

    await dialer.close()
    await listener.close()

  asyncTest "Disconnecting a peer stops its liveness monitor":
    ## The other exit from `keepAliveLoop`: someone else disconnects the peer.
    ## `disconnect` has to cancel the monitor, or it holds a reference to the
    ## peer and keeps ticking for the life of the process.
    var
      listener = newTestEnv()
      dialer = newTestEnv()

    listener.node.startListening()

    let connRes = await dialer.node.rlpxConnect(newNode(listener.node.toENode()))
    check connRes.isOk()
    check await listener.node.waitForPeers(1, 5.seconds)

    let listenerPeer = listener.node.onlyPeer()
    check not listenerPeer.isNil
    check not listenerPeer.monitorDone

    await listenerPeer.disconnect(ClientQuitting)

    # Deliberately shorter than `peerLivenessInterval`: without the cancel the
    # loop still notices on its next tick, so a generous window here would pass
    # either way and guard nothing.
    check await listenerPeer.waitForMonitorExit(2.seconds)
    check listenerPeer.transport.closed
    check listener.node.numPeers == 0

    await dialer.close()
    await listener.close()

  asyncTest "Quiet but alive peers are kept by ping/pong":
    var
      listener = newTestEnv()
      dialer = newTestEnv()

    listener.node.startListening()

    let connRes = await dialer.node.rlpxConnect(newNode(listener.node.toENode()))
    check connRes.isOk()
    check await listener.node.waitForPeers(1, 5.seconds)

    # Quiet for longer than the ping interval but well inside the idle timeout:
    # the monitor should ping and the pong should refresh the stamp
    let stale = Moment.now() - 20.seconds
    for peer in listener.node.peers:
      peer.lastReceived = stale

    check await listener.node.waitForRefresh(stale, 15.seconds)
    check listener.node.numPeers == 1

    await dialer.close()
    await listener.close()
