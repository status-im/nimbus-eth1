# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, testutils, chronos,
  json_rpc/rpcclient, stew/byteutils,
  eth/keys

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

  # to avoid influencing uTP tests by discv5 sessions negotiation, at least one ping
  # should be successful
  proc pingTillSuccess(client: RpcHttpClient, enr: JsonNode): Future[void] {.async.}=
    var failed = true
    while failed:
      let pingRes = (await client.call("ping", %[enr])).getBool()
      if pingRes:
        failed = false
  
  # TODO add more scenarios
  asyncTest "Transfer 5000B of data over utp stream":
    let client = newRpcHttpClient()
    let server = newRpcHttpClient()

    await client.connect(clientContainerAddress, clientContainerPort, false)
    await server.connect(serverContainerAddress, serverContainerPort, false)

    # TODO add file to generate nice api calls
    let clientEnr = await client.call("get_record", %[])
    let serverEnr = await server.call("get_record", %[])

    let serverAddRes = await server.call("add_record", %[clientEnr])

    # we need to have successfull ping to have proper session on both sides, otherwise
    # whoareyou packet exchange may influence testing of utp
    await client.pingTillSuccess(serverEnr)

    let connectRes = await client.call("connect", %[serverEnr])

    let srvConns = (await server.call("get_connections", %[])).getElems()

    check:
      len(srvConns) == 1

    let
      clientKey = srvConns[0]
      numBytes = 5000
      bytes = generateByteSeqHex(rng[], numBytes)
      writeRes = await client.call("write", %[connectRes, %bytes])
      readRes = await server.call("read", %[clientKey, %numBytes])
      bytesReceived = readRes.getStr()

    check:
      bytes == bytesReceived
