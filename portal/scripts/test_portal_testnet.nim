# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/sequtils,
  unittest2,
  testutils,
  confutils,
  chronos,
  eth/p2p/discoveryv5/random2,
  eth/common/keys,
  ../rpc/portal_rpc_client

type PortalTestnetConf* = object
  nodeCount* {.defaultValue: 17, desc: "Number of nodes to test", name: "node-count".}:
    int

  rpcAddress* {.
    desc: "Listening address of the JSON-RPC service for all nodes",
    defaultValue: "127.0.0.1",
    name: "rpc-address"
  .}: string

  baseRpcPort* {.
    defaultValue: 10000,
    desc: "Port of the JSON-RPC service of the bootstrap (first) node",
    name: "base-rpc-port"
  .}: uint16

proc connectToRpcServers(config: PortalTestnetConf): Future[seq[RpcClient]] {.async.} =
  var clients: seq[RpcClient]
  for i in 0 ..< config.nodeCount:
    let client = newRpcHttpClient()
    await client.connect(config.rpcAddress, Port(config.baseRpcPort + uint16(i)), false)
    clients.add(client)

  return clients

# Note:
# When doing json-rpc requests following `RpcPostError` can occur:
# "Failed to send POST Request with JSON-RPC." when a `HttpClientRequestRef`
# POST request is send in the json-rpc http client.
# This error is raised when the httpclient hits error:
# "Could not send request headers", which in its turn is caused by the
# "Incomplete data sent or received" in `AsyncStream`, which is caused by
# `ECONNRESET` or `EPIPE` error (see `isConnResetError()`) on the TCP stream.
# This can occur when the server side closes the connection, which happens after
# a `httpHeadersTimeout` of default 10 seconds (set on `HttpServerRef.new()`).
# In order to avoid here hitting this timeout a `close()` is done after each
# json-rpc call. Because the first json-rpc call opens up the connection, and it
# remains open until a close() (or timeout). No need to do another connect
# before any new call as the proc `connectToRpcServers` doesn't actually connect
# to servers, as client.connect doesn't do that. It just sets the `httpAddress`.
# Yes, this client json rpc API couldn't be more confusing.
# Could also just retry each call on failure, which would set up a new
# connection.

# We are kind of abusing the unittest2 here to run json rpc tests against other
# processes. Needs to be compiled with `-d:unittest2DisableParamFiltering` or
# the confutils cli will not work.
procSuite "Portal testnet tests":
  let config = PortalTestnetConf.load()
  let rng = newRng()

  asyncTest "Discv5 - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.discv5_nodeInfo()
      await client.close()
      nodeInfos.add(nodeInfo)

    # Kick off the network by trying to add all records to each node.
    # These nodes are also set as seen, so they get passed along on findNode
    # requests.
    # Note: The amount of Records added here can be less but then the
    # probability that all nodes will still be reached needs to be calculated.
    # Note 2: One could also ping all nodes but that is much slower and more
    # error prone
    for client in clients:
      discard await client.discv5_addEnrs(
        nodeInfos.map(
          proc(x: NodeInfo): Record =
            x.enr
        )
      )
      await client.close()

    for client in clients:
      let routingTableInfo = await client.discv5_routingTableInfo()
      await client.close()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      # A node will have at least the first bucket filled. One could increase
      # this based on the probability that x amount of nodes fit in the buckets.
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      enr = await client.discv5_lookupEnr(randomNodeInfo.nodeId)
      check enr == randomNodeInfo.enr
      await client.close()

  asyncTest "Portal History - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.portal_historyNodeInfo()
      await client.close()
      nodeInfos.add(nodeInfo)

    for client in clients:
      discard await client.portal_historyAddEnrs(
        nodeInfos.map(
          proc(x: NodeInfo): Record =
            x.enr
        )
      )
      await client.close()

    for client in clients:
      let routingTableInfo = await client.portal_historyRoutingTableInfo()
      await client.close()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      enr = await client.portal_historyLookupEnr(randomNodeInfo.nodeId)
      await client.close()
      check enr == randomNodeInfo.enr
