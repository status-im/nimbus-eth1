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
  ../../nimbus/rpc/hexstrings,
  ../rpc/portal_rpc_client,
  ../rpc/eth_rpc_client,
  ../populate_db

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

  asyncTest "Discv5 - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.discv5_nodeInfo()
      nodeInfos.add(nodeInfo)

    # Kick off the network by trying to add all records to each node.
    # These nodes are also set as seen, so they get passed along on findNode
    # requests.
    # Note: The amount of Records added here can be less but then the
    # probability that all nodes will still be reached needs to be calculated.
    # Note 2: One could also ping all nodes but that is much slower and more
    # error prone
    for client in clients:
      try:
        discard await client.discv5_addEnrs(nodeInfos.map(
          proc(x: NodeInfo): Record = x.nodeENR))
      except CatchableError as e:
        # Call shouldn't fail, unless there are json rpc server/client issues
        echo e.msg
        raise e

    for client in clients:
      let routingTableInfo = await client.discv5_routingTableInfo()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      # A node will have at least the first bucket filled. One could increase
      # this based on the probability that x amount of nodes fit in the buckets.
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      try:
        enr = await client.discv5_lookupEnr(randomNodeInfo.nodeId)
      except CatchableError as e:
        echo e.msg
      check enr == randomNodeInfo.nodeENR

  asyncTest "Portal State - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.portal_state_nodeInfo()
      nodeInfos.add(nodeInfo)

    for client in clients:
      try:
        discard await client.portal_state_addEnrs(nodeInfos.map(
          proc(x: NodeInfo): Record = x.nodeENR))
      except CatchableError as e:
        # Call shouldn't fail, unless there are json rpc server/client issues
        echo e.msg
        raise e

    for client in clients:
      let routingTableInfo = await client.portal_state_routingTableInfo()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      try:
        enr = await client.portal_state_lookupEnr(randomNodeInfo.nodeId)
      except CatchableError as e:
        echo e.msg
      # TODO: For state network this occasionally fails. It might be because the
      # distance function is not used in all locations, or perhaps it just
      # doesn't converge to the target always with this distance function. To be
      # further investigated.
      skip()
      # check enr == randomNodeInfo.nodeENR

  asyncTest "Portal History - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.portal_history_nodeInfo()
      nodeInfos.add(nodeInfo)

    for client in clients:
      try:
        discard await client.portal_history_addEnrs(nodeInfos.map(
          proc(x: NodeInfo): Record = x.nodeENR))
      except CatchableError as e:
        # Call shouldn't fail, unless there are json rpc server/client issues
        echo e.msg
        raise e

    for client in clients:
      let routingTableInfo = await client.portal_history_routingTableInfo()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      try:
        enr = await client.portal_history_lookupEnr(randomNodeInfo.nodeId)
      except CatchableError as e:
        echo e.msg
      check enr == randomNodeInfo.nodeENR

  asyncTest "Portal History - Propagate blocks and do content lookups":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.portal_history_nodeInfo()
      nodeInfos.add(nodeInfo)

    const dataFile = "./fluffy/scripts/test_data/mainnet_blocks_1-5.json"
    # This will fill the first node its db with blocks from the data file. Next,
    # this node wil offer all these blocks their headers one by one.
    check (await clients[0].portal_history_propagate(dataFile))

    let blockData = readBlockData(dataFile)
    check blockData.isOk()

    for client in clients:
      # Note: Once there is the Canonical Indices Network, we don't need to
      # access this file anymore here for the block hashes.
      for hash in blockData.get().blockHashes():
        let content = await client.eth_getBlockByHash(
          hash.ethHashStr(), false)
        check content.isSome()
        check content.get().hash.get() == hash
