# Fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[options, sequtils, sugar, strutils],
  unittest2, testutils, chronos,
  json_rpc/rpcclient, stew/byteutils,
  eth/keys,
  ./utp_test_rpc_client

proc generateBytesHex(rng: var HmacDrbgContext, length: int): string =
  rng.generateBytes(length).toHex()

# Before running this test suite, there need to be two instances of the
# utp_test_app running under the tested ports: 9042, 9041.
# Those could be launched locally by running either
# ./utp_test_app --udp-listen-address=127.0.0.1 --rpc-listen-address=0.0.0.0 --udp-port=9041 --rpc-port=9041
# ./utp_test_app --udp-listen-address=127.0.0.1 --rpc-listen-address=0.0.0.0 --udp-port=9042 --rpc-port=9042
# or
# running from docker dir:
# 1. docker build -t test-utp --no-cache --build-arg BRANCH_NAME=branch-name .
# 2. SCENARIO="scenario name and params " docker-compose up

procSuite "uTP network simulator tests":
  const
    clientContainerAddress = "127.0.0.1"
    clientContainerPort = Port(9042)
    serverContainerAddress = "127.0.0.1"
    serverContainerPort = Port(9041)

  let rng = newRng()

  type
    FutureCallback[A] = proc (): Future[A] {.gcsafe, raises: [].}
  # combinator which repeatedly calls passed closure until returned future is
  # successfull
  # TODO: currently works only for non void types
  proc repeatTillSuccess[A](
      f: FutureCallback[A], maxTries: int = 20): Future[A] {.async.} =
    var i = 0
    while true:
      try:
        let res = await f()
        return res
      except CatchableError as exc:
        echo "Call failed due to " & exc.msg
        inc i

        if i < maxTries:
          continue
        else:
          raise exc
      except CancelledError as canc:
        raise canc

  proc findServerConnection(
      connections: openArray[SKey],
      clientId: NodeId,
      clientConnectionId: uint16): Option[Skey] =
    let conns: seq[SKey] =
      connections.filter((key:Skey) => key.id == (clientConnectionId + 1) and
        key.nodeId == clientId)
    if len(conns) == 0:
      none[Skey]()
    else:
      some[Skey](conns[0])

  proc setupTest():
      Future[(RpcHttpClient, NodeInfo, RpcHttpClient, NodeInfo)] {.async.} =
    let client = newRpcHttpClient()
    let server = newRpcHttpClient()

    await client.connect(clientContainerAddress, clientContainerPort, false)
    await server.connect(serverContainerAddress, serverContainerPort, false)

    # we may need to retry few times if the sim is not ready yet
    let clientInfo = await repeatTillSuccess(() => client.discv5_nodeInfo(), 10)
    let serverInfo = await repeatTillSuccess(() => server.discv5_nodeInfo(), 10)

    # nodes need to have an established discv5 session before the uTP test
    discard await repeatTillSuccess(() => client.discv5_ping(serverInfo.enr))

    return (client, clientInfo, server, serverInfo)

  asyncTest "100kb transfer from client to server":
    const amountOfBytes = 100_000

    let
      (client, clientInfo, server, serverInfo) = await setupTest()
      clientConnectionKey = await repeatTillSuccess(() =>
        client.utp_connect(serverInfo.enr))
      serverConnections = await repeatTillSuccess(() =>
        server.utp_get_connections())
      maybeServerConnectionKey = serverConnections.findServerConnection(
        clientInfo.nodeId, clientConnectionKey.id)

    check:
      maybeServerConnectionKey.isSome()

    let
      serverConnectionKey = maybeServerConnectionKey.unsafeGet()
      bytesToWrite = generateBytesHex(rng[], amountOfBytes)
      writeRes = await client.utp_write(clientConnectionKey, bytesToWrite)
      dataRead = await server.utp_read(serverConnectionKey, amountOfBytes)

    check:
      writeRes == true
      dataRead == bytesToWrite

  asyncTest "100kb transfer from server to client":
    # In classic uTP this would not be possible, as when uTP works over UDP the
    # client needs to transfer first, but when working over discv5 it should be
    # possible to transfer data from server to client from the start.
    const amountOfBytes = 100_000

    let
      (client, clientInfo, server, serverInfo) = await setupTest()
      clientConnectionKey = await repeatTillSuccess(() =>
        client.utp_connect(serverInfo.enr))
      serverConnections = await repeatTillSuccess(() =>
        server.utp_get_connections())
      maybeServerConnectionKey = serverConnections.findServerConnection(
        clientInfo.nodeId, clientConnectionKey.id)

    check:
      maybeServerConnectionKey.isSome()

    let
      serverConnectionKey = maybeServerConnectionKey.unsafeGet()
      bytesToWrite = generateBytesHex(rng[], amountOfBytes)
      writeRes = await server.utp_write(serverConnectionKey, bytesToWrite)
      dataRead = await client.utp_read(clientConnectionKey, amountOfBytes)

    check:
      writeRes == true
      dataRead == bytesToWrite

  asyncTest "Multiple 10kb transfers from client to server":
    const
      amountOfBytes = 10_000
      amountOfTransfers = 3

    let
      (client, clientInfo, server, serverInfo) = await setupTest()
      clientConnectionKey = await repeatTillSuccess(() =>
        client.utp_connect(serverInfo.enr))
      serverConnections = await repeatTillSuccess(() =>
        server.utp_get_connections())
      maybeServerConnectionKey = serverConnections.findServerConnection(
        clientInfo.nodeId, clientConnectionKey.id)

    check:
      maybeServerConnectionKey.isSome()

    let serverConnectionKey = maybeServerConnectionKey.unsafeGet()

    var totalBytesToWrite: string
    for i in 0..<amountOfTransfers:
      let
        bytesToWrite = generateBytesHex(rng[], amountOfBytes)
        writeRes = await client.utp_write(clientConnectionKey, bytesToWrite)

      check writeRes == true
      totalBytesToWrite.add(bytesToWrite)

    let dataRead = await server.utp_read(
      serverConnectionKey, amountOfBytes * amountOfTransfers)

    check dataRead == totalBytesToWrite

  asyncTest "Multiple 10kb transfers over multiple sockets from client to server":
    const
      amountOfBytes = 10_000
      amountOfSockets = 3

    let (client, clientInfo, server, serverInfo) = await setupTest()

    var connectionKeys: seq[(SKey, SKey)]
    for i in 0..<amountOfSockets:
      let
        clientConnectionKey = await repeatTillSuccess(() =>
          client.utp_connect(serverInfo.enr))
        serverConnections = await repeatTillSuccess(() =>
          server.utp_get_connections())
        serverConnectionKeyRes = serverConnections.findServerConnection(
          clientInfo.nodeId, clientConnectionKey.id)

      check serverConnectionKeyRes.isSome()

      connectionKeys.add((clientConnectionKey, serverConnectionKeyRes.unsafeGet()))

    for (clientConnectionKey, serverConnectionKey) in connectionKeys:
      let
        bytesToWrite = generateBytesHex(rng[], amountOfBytes)
        writeRes = await client.utp_write(clientConnectionKey, bytesToWrite)
        dataRead = await server.utp_read(serverConnectionKey, amountOfBytes)

      check:
        writeRes == true
        dataRead == bytesToWrite
