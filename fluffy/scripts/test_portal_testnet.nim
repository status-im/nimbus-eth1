# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/sequtils,
  unittest2, testutils, confutils, chronos,
  eth/p2p/discoveryv5/random2, eth/keys,
  ../rpc/portal_rpc_client

type
  PortalTestnetConf* = object
    nodeCount* {.
      defaultValue: 17
      desc: "Number of nodes to test"
      name: "node-count" .}: int

    rpcAddress* {.
      desc: "Listening address of the JSON-RPC service for all nodes"
      defaultValue: "127.0.0.1"
      name: "rpc-address" }: string

    baseRpcPort* {.
      defaultValue: 7000
      desc: "Port of the JSON-RPC service of the bootstrap (first) node"
      name: "base-rpc-port" .}: uint16

proc connectToRpcServers(config: PortalTestnetConf):
    Future[seq[RpcClient]] {.async.} =
  var clients: seq[RpcClient]
  for i in 0..<config.nodeCount:
    let client = newRpcHttpClient()
    await client.connect(
      config.rpcAddress, Port(config.baseRpcPort + uint16(i)), false)
    clients.add(client)

  return clients

# We are kind of abusing the unittest2 here to run json rpc tests against other
# processes. Needs to be compiled with `-d:unittest2DisableParamFiltering` or
# the confutils cli will not work.
procSuite "Portal testnet tests":
  let config = PortalTestnetConf.load()
  let rng = newRng()

  asyncTest "Discv5 - RoutingTableInfo at start":
    let clients = await connectToRpcServers(config)

    for i, client in clients:
      let routingTableInfo = await client.discv5_routingTableInfo()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      if i == 0: # bootstrap node has all nodes (however not all verified)
        check nodes.len == config.nodeCount - 1
      else: # Other nodes will have bootstrap node at this point, and maybe more
        check nodes.len > 0

  asyncTest "Discv5 - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    for client in clients:
      # We need to run a recursive lookup for each node to kick-off the network
      discard await client.discv5_recursiveFindNodes()

    for client in clients:
      # grab a random json-rpc client and take its `NodeInfo`
      let randomClient = sample(rng[], clients)
      let nodeInfo = await randomClient.discv5_nodeInfo()

      var enr: Record
      try:
        enr = await client.discv5_lookupEnr(nodeInfo.nodeId)
      except ValueError as e:
        echo e.msg
      check enr == nodeInfo.nodeENR

  asyncTest "Portal State - RoutingTableInfo at start":
    let clients = await connectToRpcServers(config)

    for i, client in clients:
      let routingTableInfo = await client.portal_state_routingTableInfo()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      if i == 0: # bootstrap node has all nodes (however not all verified)
        check nodes.len == config.nodeCount - 1
      else: # Other nodes will have bootstrap node at this point, and maybe more
        check nodes.len > 0

  asyncTest "Portal State - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    for client in clients:
      # We need to run a recursive lookup for each node to kick-off the network
      discard await client.portal_state_recursiveFindNodes()

    for client in clients:
      # grab a random json-rpc client and take its `NodeInfo`
      let randomClient = sample(rng[], clients)
      let nodeInfo = await randomClient.portal_state_nodeInfo()

      var enr: Record
      try:
        enr = await client.portal_state_lookupEnr(nodeInfo.nodeId)
      except ValueError as e:
        echo e.msg
      check enr == nodeInfo.nodeENR

  asyncTest "Portal History - RoutingTableInfo at start":
    let clients = await connectToRpcServers(config)

    for i, client in clients:
      let routingTableInfo = await client.portal_history_routingTableInfo()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      if i == 0: # bootstrap node has all nodes (however not all verified)
        check nodes.len == config.nodeCount - 1
      else: # Other nodes will have bootstrap node at this point, and maybe more
        check nodes.len > 0

  asyncTest "Portal History - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    for client in clients:
      # We need to run a recursive lookup for each node to kick-off the network
      discard await client.portal_history_recursiveFindNodes()

    for client in clients:
      # grab a random json-rpc client and take its `NodeInfo`
      let randomClient = sample(rng[], clients)
      let nodeInfo = await randomClient.portal_history_nodeInfo()

      var enr: Record
      try:
        enr = await client.portal_history_lookupEnr(nodeInfo.nodeId)
      except ValueError as e:
        echo e.msg
      check enr == nodeInfo.nodeENR
