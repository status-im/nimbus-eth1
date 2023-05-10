# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[options, sequtils, sugar, strutils],
  unittest2, testutils, chronos,
  json_rpc/rpcclient, stew/byteutils,
  eth/keys,
  ./utp_test_client

proc generateBytesHex(rng: var HmacDrbgContext, length: int): string =
  rng.generateBytes(length).toHex()

# Before running the test suite, there need to be two instances of the
# utp_test_app running under provided ports (9042, 9041).
# Those could be launched locally by running either
# ./utp_test_app --udp-listen-address=127.0.0.1 --rpc-listen-address=0.0.0.0 --udp-port=9041 --rpc-port=9041
# ./utp_test_app --udp-listen-address=127.0.0.1 --rpc-listen-address=0.0.0.0 --udp-port=9042 --rpc-port=9042
# or
# running from docker dir:
# 1. docker build -t test-utp --no-cache --build-arg BRANCH_NAME=branch-name .
# 2. SCENARIO="scenario name and params " docker-compose up
procSuite "uTP integration tests":
  let rng = newRng()
  let clientContainerAddress = "127.0.0.1"
  let clientContainerPort = Port(9042)

  let serverContainerAddress = "127.0.0.1"
  let serverContainerPort = Port(9041)

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

    # we may need to retry few times if the simm is not ready yet
    let clientInfo = await repeatTillSuccess(() => client.discv5_nodeInfo(), 10)

    let serverInfo = await repeatTillSuccess(() => server.discv5_nodeInfo(), 10)

    # nodes need to have established session before the utp try
    discard await repeatTillSuccess(() => client.discv5_ping(serverInfo.enr))

    return (client, clientInfo, server, serverInfo)

  asyncTest "Transfer 100k bytes of data over utp stream from client to server":
    let (client, clientInfo, server, serverInfo) = await setupTest()
    let numOfBytes = 100000
    let
      clientConnectionKey = await repeatTillSuccess(() =>
        client.utp_connect(serverInfo.enr))
      serverConnections = await repeatTillSuccess(() =>
        server.utp_get_connections())
      maybeServerConnectionKey = serverConnections.findServerConnection(
        clientInfo.nodeId, clientConnectionKey.id)

    check:
      maybeServerConnectionKey.isSome()

    let serverConnectionKey = maybeServerConnectionKey.unsafeGet()

    let
      bytesToWrite = generateBytesHex(rng[], numOfBytes)
      writeRes = await client.utp_write(clientConnectionKey, bytesToWrite)
      readData = await server.utp_read(serverConnectionKey, numOfBytes)

    check:
      writeRes == true
      readData == bytesToWrite

  asyncTest "Transfer 100k bytes of data over utp stream from server to client":
    # In classic uTP this would not be possible, as when uTP works over UDP the
    # client needs to transfer first, but when working over discv5 it should be
    # possible to transfer data from server to client from the start.
    let (client, clientInfo, server, serverInfo) = await setupTest()
    let numOfBytes = 100000
    let
      clientConnectionKey = await repeatTillSuccess(() =>
        client.utp_connect(serverInfo.enr))
      serverConnections = await repeatTillSuccess(() =>
        server.utp_get_connections())
      maybeServerConnectionKey = serverConnections.findServerConnection(
        clientInfo.nodeId, clientConnectionKey.id)

    check:
      maybeServerConnectionKey.isSome()

    let serverConnectionKey = maybeServerConnectionKey.unsafeGet()

    let
      bytesToWrite = generateBytesHex(rng[], numOfBytes)
      writeRes = await server.utp_write(serverConnectionKey, bytesToWrite)
      readData = await client.utp_read(clientConnectionKey, numOfBytes)

    check:
      writeRes == true
      readData == bytesToWrite

  asyncTest "Multiple 10k bytes transfers over utp stream":
    let (client, clientInfo, server, serverInfo) = await setupTest()
    let numOfBytes = 10000
    let
      clientConnectionKey = await repeatTillSuccess(() =>
        client.utp_connect(serverInfo.enr))
      serverConnections = await repeatTillSuccess(() =>
        server.utp_get_connections())
      maybeServerConnectionKey = serverConnections.findServerConnection(
        clientInfo.nodeId, clientConnectionKey.id)

    check:
      maybeServerConnectionKey.isSome()

    let serverConnectionKey = maybeServerConnectionKey.unsafeGet()

    let
      bytesToWrite = generateBytesHex(rng[], numOfBytes)
      bytesToWrite1 = generateBytesHex(rng[], numOfBytes)
      bytesToWrite2 = generateBytesHex(rng[], numOfBytes)
      writeRes = await client.utp_write(clientConnectionKey, bytesToWrite)
      writeRes1 = await client.utp_write(clientConnectionKey, bytesToWrite1)
      writeRes2 = await client.utp_write(clientConnectionKey, bytesToWrite2)
      readData = await server.utp_read(serverConnectionKey, numOfBytes * 3)

    let writtenData = join(@[bytesToWrite, bytesToWrite1, bytesToWrite2])

    check:
      writeRes == true
      writeRes1 == true
      writeRes2 == true
      readData == writtenData

  asyncTest "Handle mulitplie sockets over one utp server instance ":
    let (client, clientInfo, server, serverInfo) = await setupTest()
    let numOfBytes = 10000
    let
      clientConnectionKey1 = await repeatTillSuccess(() =>
        client.utp_connect(serverInfo.enr))
      clientConnectionKey2 = await repeatTillSuccess(() =>
        client.utp_connect(serverInfo.enr))
      clientConnectionKey3 = await repeatTillSuccess(() =>
        client.utp_connect(serverInfo.enr))
      serverConnections = await repeatTillSuccess(() =>
        server.utp_get_connections())

      maybeServerConnectionKey1 = serverConnections.findServerConnection(
        clientInfo.nodeId, clientConnectionKey1.id)
      maybeServerConnectionKey2 = serverConnections.findServerConnection(
        clientInfo.nodeId, clientConnectionKey2.id)
      maybeServerConnectionKey3 = serverConnections.findServerConnection(
        clientInfo.nodeId, clientConnectionKey3.id)

    check:
      maybeServerConnectionKey1.isSome()
      maybeServerConnectionKey2.isSome()
      maybeServerConnectionKey3.isSome()

    let serverConnectionKey1 = maybeServerConnectionKey1.unsafeGet()
    let serverConnectionKey2 = maybeServerConnectionKey2.unsafeGet()
    let serverConnectionKey3 = maybeServerConnectionKey3.unsafeGet()

    let
      bytesToWrite1 = generateBytesHex(rng[], numOfBytes)
      bytesToWrite2 = generateBytesHex(rng[], numOfBytes)
      bytesToWrite3 = generateBytesHex(rng[], numOfBytes)

      writeRes1 = await client.utp_write(clientConnectionKey1, bytesToWrite1)
      writeRes2 = await client.utp_write(clientConnectionKey2, bytesToWrite2)
      writeRes3 = await client.utp_write(clientConnectionKey3, bytesToWrite3)

      readData1 = await server.utp_read(serverConnectionKey1, numOfBytes)
      readData2 = await server.utp_read(serverConnectionKey2, numOfBytes)
      readData3 = await server.utp_read(serverConnectionKey3, numOfBytes)

    check:
      writeRes1 == true
      writeRes2 == true
      writeRes3 == true

      # all data was delivered to correct sockets
      readData1 == bytesToWrite1
      readData2 == bytesToWrite2
      readData3 == bytesToWrite3
