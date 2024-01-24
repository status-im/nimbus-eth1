# Nimbus - Portal Network
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronos, testutils/unittests,
  json_rpc/[rpcproxy, rpcserver], json_rpc/clients/httpclient,
  stint,eth/p2p/discoveryv5/enr, eth/keys,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../rpc/rpc_discovery_api,
  ./test_helpers

type TestCase = ref object
  localDiscovery: discv5_protocol.Protocol
  server: RpcProxy
  client: RpcHttpClient

proc setupTest(rng: ref HmacDrbgContext): Future[TestCase] {.async.} =
  let
    localSrvAddress = "127.0.0.1"
    localSrvPort = 8545
    ta = initTAddress(localSrvAddress, localSrvPort)
    localDiscoveryNode = initDiscoveryNode(
      rng, PrivateKey.random(rng[]), localAddress(20302))
    fakeProxyConfig = getHttpClientConfig("http://127.0.0.1:8546")
    client = newRpcHttpClient()

  var rpcHttpServerWithProxy = RpcProxy.new([ta], fakeProxyConfig)

  rpcHttpServerWithProxy.installDiscoveryApiHandlers(localDiscoveryNode)

  await rpcHttpServerWithProxy.start()
  await client.connect(localSrvAddress, Port(localSrvPort), false)
  return TestCase(localDiscovery: localDiscoveryNode, server: rpcHttpServerWithProxy, client: client)

proc stop(testCase: TestCase) {.async.} =
  await testCase.server.stop()
  await testCase.server.closeWait()
  await testCase.localDiscovery.closeWait()

procSuite "Discovery RPC":
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
      nodeId == "0x" & tc.localDiscovery.localNode.id.toHex()

    waitFor tc.stop()
