import
  eth/p2p, eth/p2p/rlpx,
  chronos, testutils/unittests,
  ../nimbus/sync/protocol

var nextPort = 30303

proc localAddress*(port: int): Address =
  let port = Port(port)
  result = Address(udpPort: port, tcpPort: port,
                   ip: parseIpAddress("127.0.0.1"))

proc setupTestNode*(
    rng: ref HmacDrbgContext,
    capabilities: varargs[ProtocolInfo, `protocolInfo`]): EthereumNode {.gcsafe.} =
  # Don't create new RNG every time in production code!
  let keys1 = KeyPair.random(rng[])
  var node = newEthereumNode(
    keys1, localAddress(nextPort), NetworkId(1),
    addAllCapabilities = false,
    bindUdpPort = Port(nextPort), bindTcpPort = Port(nextPort),
    rng = rng)
  nextPort.inc
  for capability in capabilities:
    node.addCapability capability

  node


suite "Testing protocol handlers":
  asyncTest "Failing connection handler":
    let rng = newRng()

    var node1 = setupTestNode(rng, eth)
    var node2 = setupTestNode(rng, eth)
    node2.startListening()
    let peer = await node1.rlpxConnect(newNode(node2.toENode()))
    check:
      peer.isNil == false
      # To check if the disconnection handler did not run
      #node1.protocolState(eth).count == 0
