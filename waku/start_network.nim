import
  strformat, osproc, net, confutils, strformat, chronicles,
  eth/keys, eth/p2p/enode

const
  defaults ="--log-level:DEBUG --log-metrics --metrics-server --rpc"
  wakuNodeBin = "./build/wakunode"
  portOffset = 2

type
  NodeType = enum
    FullNode = "--waku-mode:WakuSan",
    LightNode = "--light-node:on",
    WakuNode = "--light-node:on --waku-mode:WakuChan"

  Topology = enum
    Star,
    FullMesh,
    DiscoveryBased # Whatever topology the discovery brings

  WakuNetworkConf* = object
    topology* {.
      desc: "Set the network topology."
      defaultValue: Star
      name: "topology" }: Topology

    amount* {.
      desc: "Amount of full nodes to be started."
      defaultValue: 4
      name: "amount" }: int

    testNodePeers* {.
      desc: "Amount of peers a test node should connect to."
      defaultValue: 1
      name: "test-node-peers" }: int

  NodeInfo* = object
    cmd: string
    master: bool
    enode: string
    label: string

proc initNodeCmd(nodeType: NodeType, shift: int, staticNodes: seq[string] = @[],
    discovery = false, bootNodes: seq[string] = @[], master = false,
    label: string): NodeInfo =
  let
    keypair = newKeyPair()
    address = Address(ip: parseIpAddress("127.0.0.1"),
      udpPort: (30303 + shift).Port, tcpPort: (30303 + shift).Port)
    enode = ENode(pubkey: keypair.pubkey, address: address)

  result.cmd = wakuNodeBin & " " & defaults & " "
  result.cmd &= $nodeType & " "
  result.cmd &= "--nodekey:" & $keypair.seckey & " "
  result.cmd &= "--ports-shift:" & $shift & " "
  if discovery:
    result.cmd &= "--discovery:on" & " "
    if bootNodes.len > 0:
      for bootNode in bootNodes:
        result.cmd &= "--bootnodes:" & bootNode & " "
  else:
    result.cmd &= "--discovery:off" & " "
  if staticNodes.len > 0:
    for staticNode in staticNodes:
      result.cmd &= "--staticnodes:" & staticNode & " "

  result.master = master
  result.enode = $enode
  result.label = label

  debug "Node command created.", cmd=result.cmd

proc starNetwork(amount: int): seq[NodeInfo] =
  let masterNode = initNodeCmd(FullNode, portOffset, master = true,
    label = "master node")
  result.add(masterNode)
  for i in 1..<amount:
    result.add(initNodeCmd(FullNode, portOffset + i, @[masterNode.enode],
      label = "full node"))

proc fullMeshNetwork(amount: int): seq[NodeInfo] =
  debug "amount", amount
  for i in 0..<amount:
    var staticnodes: seq[string]
    for item in result:
      staticnodes.add(item.enode)
    result.add(initNodeCmd(FullNode, portOffset + i, staticnodes,
      label = "full node"))

proc discoveryNetwork(amount: int): seq[NodeInfo] =
  let bootNode = initNodeCmd(FullNode, portOffset, discovery = true,
    master = true, label = "boot node")
  result.add(bootNode)
  for i in 1..<amount:
    result.add(initNodeCmd(FullNode, portOffset + i, label = "full node",
      discovery = true, bootNodes = @[bootNode.enode]))

let conf = WakuNetworkConf.load()

var nodes: seq[NodeInfo]
case conf.topology:
  of Star:
    nodes = starNetwork(conf.amount)
  of FullMesh:
    nodes = fullMeshNetwork(conf.amount)
  of DiscoveryBased:
    nodes = discoveryNetwork(conf.amount)

var staticnodes: seq[string]
for i in 0..<conf.testNodePeers:
  staticnodes.add(nodes[i].enode)
# Waku light node
nodes.add(initNodeCmd(WakuNode, 0, staticnodes, label = "light Waku node"))
# Regular light node
nodes.add(initNodeCmd(LightNode, 1, staticnodes, label = "light node"))

var commandStr = "multitail -s 2 -M 0 -x \"Waku Simulation\""
var count = 0
var sleepDuration = 0
for node in nodes:
  if conf.topology in {Star, DiscoveryBased}:
    sleepDuration = if node.master: 0
                    else: 1
  commandStr &= &" -cT ansi -t 'node #{count} {node.label}' -l 'sleep {sleepDuration}; {node.cmd}; echo [node execution completed]; while true; do sleep 100; done'"
  if conf.topology == FullMesh:
    sleepDuration += 1
  count += 1

let errorCode = execCmd(commandStr)
if errorCode != 0:
  error "launch command failed", command=commandStr
