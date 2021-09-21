# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronos, unittest2, stew/shims/net,
  json_rpc/[rpcproxy, rpcserver], json_rpc/clients/httpclient,
  stint,eth/p2p/discoveryv5/enr, eth/keys,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../rpc/discovery_api, ./test_helpers

type TestCase = ref object
  localDiscovery: discv5_protocol.Protocol 
  server: RpcProxy
  client: RpcHttpClient

proc setupTest(rng: ref BrHmacDrbgContext): Future[TestCase] {.async.} =
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
  await client.connect(localSrvAddress, Port(localSrvPort))
  return TestCase(localDiscovery: localDiscoveryNode, server: rpcHttpServerWithProxy, client: client)

proc stop(t: TestCase) {.async.} =
  await t.server.stop()
  await t.server.closeWait()
  await t.localDiscovery.closeWait()


proc discoveryRpcMain*() =
  suite "Discovery Rpc":
    let rng = newRng()

    asyncTest "Get local node info":
      let tc = await setupTest(rng)
      let resp = await tc.client.call("discv5_nodeInfo", %[])

      check:
        resp.contains("node_id")
        resp["node_id"].kind == JString
        resp.contains("enr")
        resp["enr"].kind == JString

      let nodeId = resp["node_id"].getStr()
      let nodeEnr = resp["enr"].getStr()

      check:
        nodeEnr == tc.localDiscovery.localNode.record.toURI()
        nodeId == "0x" & tc.localDiscovery.localNode.id.toHex()

      waitFor tc.stop()

when isMainModule:
  discoveryRpcMain()
