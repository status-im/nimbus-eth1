# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/strutils,
  chronos,
  stint,
  eth/common/keys,
  ../../execution_chain/networking/[p2p, discoveryv4]

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
    keys1, localAddress(nextPort),
    networkId = 1.u256,
    addAllCapabilities = false,
    bindUdpPort = Port(nextPort),
    bindTcpPort = Port(nextPort),
    rng = rng)
  nextPort.inc
  for capability in capabilities:
    node.addCapability capability

  node

template sourceDir*: string = currentSourcePath.rsplit(DirSep, 1)[0]

proc recvMsgMock*(msg: openArray[byte]): tuple[msgId: uint, msgData: Rlp] =
  var rlp = rlpFromBytes(msg)

  let msgId = rlp.read(uint32)
  return (msgId.uint, rlp)
