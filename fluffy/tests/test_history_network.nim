# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  testutils/unittests, chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol, eth/p2p/discoveryv5/routing_table,
  eth/common/eth_types,
  eth/rlp,
  ../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../network/history/[history_network, accumulator, history_content],
  ../../nimbus/constants,
  ../content_db,
  ./test_helpers


type HistoryNode = ref object
  discoveryProtocol*: discv5_protocol.Protocol
  historyNetwork*: HistoryNetwork

proc newHistoryNode(rng: ref HmacDrbgContext, port: int): HistoryNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new("", uint32.high, inMemory = true)
    socketConfig = SocketConfig.init(
      incomingSocketReceiveTimeout = none(Duration),
      payloadSize = uint32(maxUtpPayloadSize)
    )
    hn = HistoryNetwork.new(node, db)
    streamTransport = UtpDiscv5Protocol.new(
      node,
      utpProtocolId,
      registerIncomingSocketCallback(@[hn.portalProtocol.stream]),
      allowRegisteredIdCallback(@[hn.portalProtocol.stream]),
      socketConfig
    )

  hn.setStreamTransport(streamTransport)

  return HistoryNode(discoveryProtocol: node, historyNetwork: hn)

proc portalWireProtocol(hn: HistoryNode): PortalProtocol =
  hn.historyNetwork.portalProtocol

proc localNodeInfo(hn: HistoryNode): Node =
  hn.discoveryProtocol.localNode

proc start(hn: HistoryNode) =
  hn.historyNetwork.start()

proc stop(hn: HistoryNode) {.async.} =
  hn.historyNetwork.stop()
  await hn.discoveryProtocol.closeWait()

procSuite "History Content Network":
  let rng = newRng()
  asyncTest "Get block by block number":
    let
      historyNode1 = newHistoryNode(rng, 20302)
      historyNode2 = newHistoryNode(rng, 20303)

    historyNode1.start()
    historyNode2.start()

    # enough headers so there will be at least two epochs
    let numHeaders = 9000
    var headers: seq[BlockHeader]
    for i in 0..numHeaders:
      var bh = BlockHeader()
      bh.blockNumber = u256(i)
      bh.difficulty = u256(i)
      # empty so that we won't care about creating fake block bodies
      bh.ommersHash = EMPTY_UNCLE_HASH
      bh.txRoot = BLANK_ROOT_HASH
      headers.add(bh)

    let masterAccumulator = buildAccumulator(headers)
    let epochAccumulators = buildAccumulatorData(headers)

    # both nodes start with the same master accumulator, but only node2 have all
    # headers and all epoch accumulators
    await historyNode1.historyNetwork.initMasterAccumulator(some(masterAccumulator))
    await historyNode2.historyNetwork.initMasterAccumulator(some(masterAccumulator))

    for h in headers:
      let headerHash = h.blockHash()
      let bk = BlockKey(chainId: 1'u16, blockHash: headerHash)
      let ck = ContentKey(contentType: blockHeader, blockHeaderKey: bk)
      let ci = toContentId(ck)
      let headerEncoded = rlp.encode(h)
      historyNode2.portalWireProtocol().storeContent(ci, headerEncoded)

    for ad in epochAccumulators:
      let (ck, epochAccumulator) = ad
      let id = toContentId(ck)
      let bytes = SSZ.encode(epochAccumulator)
      historyNode2.portalWireProtocol().storeContent(id, bytes)

    check historyNode1.portalWireProtocol().addNode(historyNode2.localNodeInfo()) == Added
    check historyNode2.portalWireProtocol().addNode(historyNode1.localNodeInfo()) == Added

    check (await historyNode1.portalWireProtocol().ping(historyNode2.localNodeInfo())).isOk()
    check (await historyNode2.portalWireProtocol().ping(historyNode1.localNodeInfo())).isOk()


    for i in 0..numHeaders:
      let blockResponse = await historyNode1.historyNetwork.getBlock(1'u16, u256(i))

      check:
        blockResponse.isOk()

      let blockOpt = blockResponse.get()

      check:
        blockOpt.isSome()

      let (blockHeader, blockBody) = blockOpt.unsafeGet()

      check:
        blockHeader == headers[i]

    await historyNode1.stop()
    await historyNode2.stop()
