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
  ../../execution_chain/networking/p2p,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/core/tx_pool,
  ../../execution_chain/sync/wire_protocol,
  ../../execution_chain/conf

type
  TestEnv* = ref object
    config : ExecutionClientConf
    com    : CommonRef
    node*  : EthereumNode
    txPool : TxPoolRef
    chain  : ForkedChainRef
    wire   : EthWireRef

const
  genesisFile = "tests/customgenesis/cancun123.json"

proc makeCom(config: ExecutionClientConf): CommonRef =
  let com = CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    config.networkId,
    config.networkParams
  )
  com.taskpool = Taskpool.new()
  com

proc envConfig(): ExecutionClientConf =
  makeConfig(@[
    "--network:" & genesisFile,
    "--listen-address: 127.0.0.1",
  ])

var nextPort = 30303

func localAddress*(port: int): enode.Address =
  enode.Address(udpPort: Port(port), tcpPort: Port(port), ip: parseIpAddress("127.0.0.1"))

proc setupTestNode(rng: ref HmacDrbgContext): EthereumNode {.gcsafe.} =
  # Don't create new RNG every time in production code!
  let keys1 = KeyPair.random(rng[])
  var node = newEthereumNode(
    keys1,
    Opt.some(parseIpAddress("127.0.0.1")),
    Opt.some(Port(nextPort)),
    Opt.some(Port(nextPort)),
    networkId = 1.u256,
    bindUdpPort = Port(nextPort),
    bindTcpPort = Port(nextPort),
    rng = rng)
  nextPort.inc

  node

proc newTestEnv*(): TestEnv =
  let
    rng    = newRng()
    node   = setupTestNode(rng)
    config = envConfig()
    com    = makeCom(config)
    chain  = ForkedChainRef.init(com, enableQueue = true)
    txPool = TxPoolRef.new(chain)
    wire   = node.addEthHandlerCapability(txPool)

  TestEnv(
    config : config,
    com    : com,
    node   : node,
    txPool : txPool,
    chain  : chain,
    wire   : wire,
  )

proc close*(env: TestEnv) =
  if env.node.listeningServer.isNil.not:
    waitFor env.node.closeWait()
  waitFor env.wire.stop()
  waitFor env.chain.stopProcessingQueue()

template sourceDir*: string = currentSourcePath.rsplit(DirSep, 1)[0]

proc recvMsgMock*(msg: openArray[byte]): tuple[msgId: uint, msgData: Rlp] =
  var rlp = rlpFromBytes(msg)

  let msgId = rlp.read(uint32)
  return (msgId.uint, rlp)
