# Nimbus - Portal Network
# Copyright (c) 2025 Status Research & Development GmbH
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
  eth/common/keys,
  ../../network/wire/portal_protocol,
  ../../rpc/rpc_portal_common_api,
  ../history_network_tests/history_test_helpers

type HistoryTestCase = ref object
  historyNode: HistoryNode
  server: RpcHttpServer
  client: RpcHttpClient

proc setupHistoryTest(
    rng: ref HmacDrbgContext
): Future[HistoryTestCase] {.async: (raises: [CancelledError]).} =
  let
    localSrvAddress = "127.0.0.1"
    localSrvPort = 0 # let the OS choose a port
    ta =
      try:
        initTAddress(localSrvAddress, localSrvPort)
      except TransportAddressError as e:
        raiseAssert(e.msg)
    historyNode = newHistoryNetwork(rng, 20332)
    client = newRpcHttpClient()

  historyNode.start()

  let rpcHttpServer = RpcHttpServer.new()
  try:
    rpcHttpServer.addHttpServer(ta, maxRequestBodySize = 16 * 1024 * 1024)
  except JsonRpcError as e:
    raiseAssert("Failed to add HTTP server: " & e.msg)

  RpcServer(rpcHttpServer).installPortalCommonApiHandlers(
    historyNode.portalProtocol, PortalSubnetwork.history
  )

  rpcHttpServer.start()
  try:
    await client.connect(localSrvAddress, rpcHttpServer.localAddress[0].port, false)
  except CatchableError as e:
    raiseAssert("Failed to connect to RPC server: " & e.msg)

  HistoryTestCase(historyNode: historyNode, server: rpcHttpServer, client: client)

proc stop(testCase: HistoryTestCase) {.async: (raises: [CancelledError]).} =
  try:
    await testCase.server.stop()
    await testCase.server.closeWait()
  except CatchableError as e:
    raiseAssert("Failed to stop RPC server: " & e.msg)

  await testCase.historyNode.stop()

procSuite "Portal Common JSON-RPC API":
  let rng = newRng()

  asyncTest "portal_historyNodeInfo":
    let
      tc = await setupHistoryTest(rng)
      jsonBytes = await tc.client.call("portal_historyNodeInfo", %[])
      resp = JrpcConv.decode(jsonBytes.string, JsonNode)

    check:
      resp.contains("enr")
      resp["enr"].kind == JString
      resp.contains("nodeId")
      resp["nodeId"].kind == JString

    let localNodeId = resp["nodeId"].getStr()
    check:
      localNodeId == tc.historyNode.localNode.id.toBytesBE().to0xHex()

    await tc.stop()

  asyncTest "portal_historyRoutingTableInfo":
    let
      tc = await setupHistoryTest(rng)
      jsonBytes = await tc.client.call("portal_historyRoutingTableInfo", %[])
      resp = JrpcConv.decode(jsonBytes.string, JsonNode)

    check:
      resp.contains("localNodeId")
      resp["localNodeId"].kind == JString
      resp.contains("buckets")
      resp["buckets"].kind == JArray

    await tc.stop()

  asyncTest "portal_historyAddEnr":
    let
      tc = await setupHistoryTest(rng)

      testHistoryNode = newHistoryNetwork(rng, 20333)
      testEnr = testHistoryNode.localNode.record

      jsonBytes = await tc.client.call("portal_historyAddEnr", %[testEnr.toURI()])
    check JrpcConv.decode(jsonBytes.string, bool)

    await testHistoryNode.stop()
    await tc.stop()

  asyncTest "portal_historyGetEnr":
    let
      tc = await setupHistoryTest(rng)
      # Get the local node's ENR using its node ID
      nodeId = tc.historyNode.localNode.id
      jsonBytes =
        await tc.client.call("portal_historyGetEnr", %[nodeId.toBytesBE().to0xHex()])
    check JrpcConv.decode(jsonBytes.string, string) ==
      tc.historyNode.localNode.record.toURI()

    await tc.stop()

  asyncTest "portal_historyDeleteEnr":
    let
      tc = await setupHistoryTest(rng)

      testHistoryNode = newHistoryNetwork(rng, 20333)
      testNodeId = testHistoryNode.localNode.id

    # Add the node first as false if not found
    discard tc.historyNode.portalProtocol.addNode(testHistoryNode.localNode)

    let jsonBytes = await tc.client.call(
      "portal_historyDeleteEnr", %[testNodeId.toBytesBE().to0xHex()]
    )
    check JrpcConv.decode(jsonBytes.string, bool)

    await testHistoryNode.stop()
    await tc.stop()

  asyncTest "portal_historyPing":
    let tc = await setupHistoryTest(rng)

    # Other test node to ping
    let testHistoryNode = newHistoryNetwork(rng, 20333)
    testHistoryNode.start()

    # Add the test node to the main node's routing table first
    discard tc.historyNode.portalProtocol.addNode(testHistoryNode.localNode)

    let params = newJArray()
    params.add(%testHistoryNode.localNode.record.toURI())
    # Note: Not adding payloadType and payload to use defaults
    let jsonBytes = await tc.client.call("portal_historyPing", params)
    let resp = JrpcConv.decode(jsonBytes.string, JsonNode)

    check:
      resp.contains("enrSeq")
      resp["enrSeq"].kind == JInt
      resp.contains("payloadType")
      resp["payloadType"].kind == JInt
      resp.contains("payload")
      resp["payload"].kind == JObject

    let payload = resp["payload"]
    check:
      payload.contains("clientInfo")
      payload["clientInfo"].kind == JString
      payload.contains("dataRadius")
      payload["dataRadius"].kind == JString
      payload.contains("capabilities")
      payload["capabilities"].kind == JArray

    await testHistoryNode.stop()
    await tc.stop()

  asyncTest "portal_historyFindNodes":
    let tc = await setupHistoryTest(rng)

    # Other test node to send FindNodes to
    let testHistoryNode = newHistoryNetwork(rng, 20333)
    testHistoryNode.start()

    let params = newJArray()
    params.add(%testHistoryNode.localNode.record.toURI())
    params.add(%[0]) # 0 = own ENR
    let jsonBytes = await tc.client.call("portal_historyFindNodes", params)
    check JrpcConv.decode(jsonBytes.string, JsonNode).kind == JArray

    await testHistoryNode.stop()
    await tc.stop()

  asyncTest "portal_historyRecursiveFindNodes":
    let tc = await setupHistoryTest(rng)

    # Use the local node's ID for the lookup
    let nodeId = tc.historyNode.localNode.id
    let jsonBytes = await tc.client.call(
      "portal_historyRecursiveFindNodes", %[nodeId.toBytesBE().to0xHex()]
    )
    check JrpcConv.decode(jsonBytes.string, JsonNode).kind == JArray

    await tc.stop()
