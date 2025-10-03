# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronos,
  eth/common/keys,
  eth/p2p/discoveryv5/protocol,
  ../../database/content_db,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/history/history_network,
  ../test_helpers

type HistoryNode* = ref object
  discovery: protocol.Protocol
  historyNetwork*: HistoryNetwork

proc newHistoryNetwork*(
    rng: ref HmacDrbgContext,
    port: int,
    getHeaderCallback: GetHeaderCallback = defaultNoGetHeader,
): HistoryNode =
  let
    node =
      try:
        initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
      except CatchableError as e:
        raiseAssert "Failed to initialize discovery node: " & e.msg
    db = ContentDB.new(
      "",
      uint32.high,
      RadiusConfig(kind: Static, logRadius: 256),
      node.localNode.id,
      inMemory = true,
    )
    streamManager = StreamManager.new(node)

  HistoryNode(
    discovery: node,
    historyNetwork: HistoryNetwork.new(
      PortalNetwork.mainnet, node, db, streamManager, getHeaderCallback
    ),
  )

proc start*(n: HistoryNode) =
  n.discovery.start()
  n.historyNetwork.start()

proc stop*(n: HistoryNode) {.async: (raises: []).} =
  await n.historyNetwork.stop()
  await n.discovery.closeWait()
  n.historyNetwork.contentDB.close()

func portalProtocol*(n: HistoryNode): PortalProtocol =
  n.historyNetwork.portalProtocol

func localNode*(n: HistoryNode): Node =
  n.historyNetwork.localNode()
