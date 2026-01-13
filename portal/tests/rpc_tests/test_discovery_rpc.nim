# Nimbus - Portal Network
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  chronos,
  testutils/unittests,
  stew/byteutils,
  json_rpc/rpcserver,
  json_rpc/clients/httpclient,
  stint,
  eth/enr/enr,
  eth/common/keys,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../../rpc/rpc_discovery_api,
  ../test_helpers

type TestCase = ref object
  localDiscovery: discv5_protocol.Protocol
  server: RpcHttpServer
  client: RpcHttpClient

proc setupTest(
    rng: ref HmacDrbgContext
): Future[TestCase] {.async: (raises: [CancelledError]).} =
  let
    localSrvAddress = "127.0.0.1"
    localSrvPort = 0 # let the OS choose a port
    ta =
      try:
        initTAddress(localSrvAddress, localSrvPort)
      except TransportAddressError as e:
        raiseAssert(e.msg)
    localDiscoveryNode =
      try:
        initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20332))
      except CatchableError as e:
        raiseAssert "Failed to initialize discovery node: " & e.msg
    client = newRpcHttpClient()

  let rpcHttpServer = RpcHttpServer.new()

  try:
    rpcHttpServer.addHttpServer(ta, maxRequestBodySize = 16 * 1024 * 1024)
  except JsonRpcError as e:
    raiseAssert("Failed to add HTTP server: " & e.msg)

  rpcHttpServer.installDiscoveryApiHandlers(localDiscoveryNode)

  rpcHttpServer.start()
  try:
    await client.connect(localSrvAddress, rpcHttpServer.localAddress[0].port, false)
  except CatchableError as e:
    raiseAssert("Failed to connect to RPC server: " & e.msg)

  TestCase(localDiscovery: localDiscoveryNode, server: rpcHttpServer, client: client)

proc stop(testCase: TestCase) {.async: (raises: [CancelledError]).} =
  try:
    await testCase.server.stop()
    await testCase.server.closeWait()
  except CatchableError as e:
    raiseAssert("Failed to stop RPC server: " & e.msg)

  await testCase.localDiscovery.closeWait()

procSuite "Discovery v5 JSON-RPC API":
  let rng = newRng()

  asyncTest "Get local node info":
    let tc = await setupTest(rng)
    let jsonBytes = await tc.client.call("discv5_nodeInfo", %[])
    let resp = EthJson.decode(jsonBytes.string, JsonNode)

    check:
      resp.contains("nodeId")
      resp["nodeId"].kind == JString
      resp.contains("enr")
      resp["enr"].kind == JString

    let nodeId = resp["nodeId"].getStr()
    let nodeEnr = resp["enr"].getStr()

    check:
      nodeEnr == tc.localDiscovery.localNode.record.toURI()
      nodeId == tc.localDiscovery.localNode.id.toBytesBE().to0xHex()

    await tc.stop()
