# Nimbus - Portal Network
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronos,
  testutils/unittests,
  stew/byteutils,
  json_rpc/rpcserver,
  json_rpc/clients/httpclient,
  stint,
  eth/p2p/discoveryv5/enr,
  eth/common/keys,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../../rpc/rpc_discovery_api,
  ../test_helpers

type TestCase = ref object
  localDiscovery: discv5_protocol.Protocol
  server: RpcHttpServer
  client: RpcHttpClient

proc setupTest(rng: ref HmacDrbgContext): Future[TestCase] {.async.} =
  let
    localSrvAddress = "127.0.0.1"
    localSrvPort = 0 # let the OS choose a port
    ta = initTAddress(localSrvAddress, localSrvPort)
    localDiscoveryNode =
      initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20332))
    client = newRpcHttpClient()

  let rpcHttpServer = RpcHttpServer.new()
  rpcHttpServer.addHttpServer(ta, maxRequestBodySize = 4 * 1_048_576)

  rpcHttpServer.installDiscoveryApiHandlers(localDiscoveryNode)

  rpcHttpServer.start()
  await client.connect(localSrvAddress, rpcHttpServer.localAddress[0].port, false)
  return
    TestCase(localDiscovery: localDiscoveryNode, server: rpcHttpServer, client: client)

proc stop(testCase: TestCase) {.async.} =
  await testCase.server.stop()
  await testCase.server.closeWait()
  await testCase.localDiscovery.closeWait()

procSuite "Discovery v5 JSON-RPC API":
  let rng = newRng()

  asyncTest "Get local node info":
    let tc = await setupTest(rng)
    let jsonBytes = await tc.client.call("discv5_nodeInfo", %[])
    let resp = JrpcConv.decode(jsonBytes.string, JsonNode)

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

    waitFor tc.stop()
