# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol, eth/p2p/discoveryv5/routing_table,
  eth/common/eth_types_rlp,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  ../../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../../network/beacon_light_client/[light_client_network, light_client_content],
  ../../content_db,
  ../test_helpers

type LightClientNode* = ref object
  discoveryProtocol*: discv5_protocol.Protocol
  lightClientNetwork*: LightClientNetwork

proc getTestForkDigests*(): ForkDigests =
  return ForkDigests(
    phase0: ForkDigest([0'u8, 0, 0, 1]),
    altair: ForkDigest([0'u8, 0, 0, 2]),
    bellatrix: ForkDigest([0'u8, 0, 0, 3]),
    capella: ForkDigest([0'u8, 0, 0, 4]),
    sharding: ForkDigest([0'u8, 0, 0, 5])
  )

proc newLCNode*(
    rng: ref HmacDrbgContext,
    port: int,
    forks: ForkDigests = getTestForkDigests()): LightClientNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new("", uint32.high, inMemory = true)
    streamManager = StreamManager.new(node)
    hn = LightClientNetwork.new(node, db, streamManager, forks)

  return LightClientNode(discoveryProtocol: node, lightClientNetwork: hn)

proc portalProtocol*(hn: LightClientNode): PortalProtocol =
  hn.lightClientNetwork.portalProtocol

proc localNode*(hn: LightClientNode): Node =
  hn.discoveryProtocol.localNode

proc start*(hn: LightClientNode) =
  hn.lightClientNetwork.start()

proc stop*(hn: LightClientNode) {.async.} =
  hn.lightClientNetwork.stop()
  await hn.discoveryProtocol.closeWait()

proc containsId*(hn: LightClientNode, contentId: ContentId): bool =
  return hn.lightClientNetwork.contentDB.get(contentId).isSome()
