# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[options, sequtils, sugar],
  unittest2, testutils, chronos,
  json_rpc/rpcclient, stew/byteutils,
  eth/keys,
  ./utp_test_client

proc generateByteSeq(rng: var BrHmacDrbgContext, length: int): seq[byte] =
  var bytes = newSeq[byte](length)
  brHmacDrbgGenerate(rng, bytes)
  return bytes

proc generateByteSeqHex(rng: var BrHmacDrbgContext, length: int): string =
  generateByteSeq(rng, length).toHex()

# Before running the suit, there need to be two instances of utp_test_app running
# under provided ports (9042, 9041).
# Those could be launched locally by running either
# ./utp_test_app --udp-listen-address=127.0.0.1 --rpc-listen-address=0.0.0.0 --udp-port=9041 --rpc-port=9041
# ./utp_test_app --udp-listen-address=127.0.0.1 --rpc-listen-address=0.0.0.0 --udp-port=9042 --rpc-port=9042
# or 
# 1. running in docker dir: docker build -t test-utp --no-cache --build-arg BRANCH_NAME=branch-name .
# 2. running in docke dir: SCENARIO="scenario name and params " docker-compose up
procSuite "Utp integration tests":
  let rng = newRng()
  let clientContainerAddress = "127.0.0.1"
  let clientContainerPort = Port(9042)

  let serverContainerAddress = "127.0.0.1"
  let serverContainerPort = Port(9041)

  # combinator which repeatadly calls passed closure until returned future is 
  # successfull
  proc repeatTillSuccess[A](f: proc (): Future[A] {.gcsafe.}): Future[A] {.async.}=
    while true:
      let resFut = f()
      yield resFut

      if resFut.failed():
        continue
      else:
        when A is void:
          return
        else:
          return resFut.read()

  proc findServerConnection(
    connections: openArray[SKey],
    clientId: NodeId,
    clientConnectionId: uint16): Option[Skey] = 
    let conns: seq[SKey] = 
      connections.filter((key:Skey) => key.id == (clientConnectionId + 1) and key.nodeId == clientId)
    if len(conns) == 0:
      none[Skey]()
    else:
      some[Skey](conns[0])

  # TODO add more scenarios
  asyncTest "Transfer 100k bytes of data over utp stream":
    let client = newRpcHttpClient()
    let server = newRpcHttpClient()
    let numOfBytes = 100000

    await client.connect(clientContainerAddress, clientContainerPort, false)
    await server.connect(serverContainerAddress, serverContainerPort, false)

    let clientInfo = await client.discv5_nodeInfo()
    let serverInfo = await server.discv5_nodeInfo()

    # nodes need to have established session before the utp try
    discard await repeatTillSuccess(() => client.discv5_ping(serverInfo.nodeEnr))

    let 
      clientConnectionKey = await repeatTillSuccess(() => client.utp_connect(serverInfo.nodeEnr))
      serverConnections = await repeatTillSuccess(() => server.utp_get_connections())
      maybeServerConnectionKey = serverConnections.findServerConnection(clientInfo.nodeId, clientConnectionKey.id)

    check:
      maybeServerConnectionKey.isSome()

    let serverConnectionKey = maybeServerConnectionKey.unsafeGet()

    let
      bytesToWrite = generateByteSeqHex(rng[], numOfBytes)
      writeRes = await client.utp_write(clientConnectionKey, bytesToWrite)
      readData = await server.utp_read(serverConnectionKey, numOfBytes)

    check:
      writeRes == true
      readData == bytesToWrite
