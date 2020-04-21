import
  strformat, os, osproc, net, confutils, strformat, chronicles, json, strutils,
  eth/keys, eth/p2p/enode

const
  defaults ="--log-level:DEBUG --log-metrics --metrics-server --rpc"
  wakuNodeBin = "build" / "wakunode"
  metricsDir = "waku" / "metrics"
  portOffset = 2

type
  NodeType = enum
    FullNode = "",
    LightNode = "--light-node:on",

  Topology = enum
    Star,
    FullMesh,
    DiscoveryBased # Whatever topology the discovery brings

  WakuNetworkConf* = object
    topology* {.
      desc: "Set the network topology."
      defaultValue: Star
      name: "topology" .}: Topology

    amount* {.
      desc: "Amount of full nodes to be started."
      defaultValue: 4
      name: "amount" .}: int

    testNodePeers* {.
      desc: "Amount of peers a test node should connect to."
      defaultValue: 1
      name: "test-node-peers" .}: int

  NodeInfo* = object
    cmd: string
    master: bool
    enode: string
    shift: int
    label: string

proc initNodeCmd(nodeType: NodeType, shift: int, staticNodes: seq[string] = @[],
    discovery = false, bootNodes: seq[string] = @[], topicInterest = false,
    master = false, label: string): NodeInfo =
  let
    keypair = KeyPair.random().tryGet()
    address = Address(ip: parseIpAddress("127.0.0.1"),
      udpPort: (30303 + shift).Port, tcpPort: (30303 + shift).Port)
    enode = ENode(pubkey: keypair.pubkey, address: address)

  result.cmd = wakuNodeBin & " " & defaults & " "
  result.cmd &= $nodeType & " "
  result.cmd &= "--waku-topic-interest:" & $topicInterest & " "
  result.cmd &= "--nodekey:" & $keypair.seckey & " "
  result.cmd &= "--ports-shift:" & $shift & " "
  if discovery:
    result.cmd &= "--discovery:on" & " "
    if bootNodes.len > 0:
      for bootNode in bootNodes:
        result.cmd &= "--bootnode:" & bootNode & " "
  else:
    result.cmd &= "--discovery:off" & " "
  if staticNodes.len > 0:
    for staticNode in staticNodes:
      result.cmd &= "--staticnode:" & staticNode & " "

  result.master = master
  result.enode = $enode
  result.shift = shift
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

proc generatePrometheusConfig(nodes: seq[NodeInfo], outputFile: string) =
  var config = """
  global:
    scrape_interval: 1s

  scrape_configs:
    - job_name: "wakusim"
      static_configs:"""
  var count = 0
  for node in nodes:
    let port = 8008 + node.shift
    config &= &"""

      - targets: ['127.0.0.1:{port}']
        labels:
          node: '{count}'"""
    count += 1

  var (path, file) = splitPath(outputFile)
  createDir(path)
  writeFile(outputFile, config)

proc proccessGrafanaDashboard(nodes: int, inputFile: string,
    outputFile: string) =
  # from https://github.com/status-im/nim-beacon-chain/blob/master/tests/simulation/process_dashboard.nim
  var
    inputData = parseFile(inputFile)
    panels = inputData["panels"].copy()
    numPanels = len(panels)
    gridHeight = 0
    outputData = inputData

  for panel in panels:
    if panel["gridPos"]["x"].getInt() == 0:
      gridHeight += panel["gridPos"]["h"].getInt()

  outputData["panels"] = %* []
  for nodeNum in 0 .. (nodes - 1):
    var
      nodePanels = panels.copy()
      panelIndex = 0
    for panel in nodePanels.mitems:
      panel["title"] = %* replace(panel["title"].getStr(), "#0", "#" & $nodeNum)
      panel["id"] = %* (panelIndex + (nodeNum * numPanels))
      panel["gridPos"]["y"] = %* (panel["gridPos"]["y"].getInt() + (nodeNum * gridHeight))
      var targets = panel["targets"]
      for target in targets.mitems:
        target["expr"] = %* replace(target["expr"].getStr(), "{node=\"0\"}", "{node=\"" & $nodeNum & "\"}")
      outputData["panels"].add(panel)
      panelIndex.inc()

  outputData["uid"] = %* (outputData["uid"].getStr() & "a")
  outputData["title"] = %* (outputData["title"].getStr() & " (all nodes)")
  writeFile(outputFile, pretty(outputData))

when isMainModule:
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
    # TODO: could also select nodes randomly
    staticnodes.add(nodes[i].enode)
  # light node with topic interest
  nodes.add(initNodeCmd(LightNode, 0, staticnodes, topicInterest = true,
    label = "light node topic interest"))
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

  generatePrometheusConfig(nodes, metricsDir / "prometheus" / "prometheus.yml")
  proccessGrafanaDashboard(nodes.len,
    "waku" / "examples" / "waku-grafana-dashboard.json",
    metricsDir / "waku-sim-all-nodes-grafana-dashboard.json")

  let errorCode = execCmd(commandStr)
  if errorCode != 0:
    error "launch command failed", command=commandStr
