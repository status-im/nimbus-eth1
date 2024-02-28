# Nimbus - Portal Network
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  beacon_chain/spec/forks,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/beacon/[beacon_init_loader, beacon_network],
  ../test_helpers

type BeaconNode* = ref object
  discoveryProtocol*: discv5_protocol.Protocol
  beaconNetwork*: BeaconNetwork

proc newLCNode*(
    rng: ref HmacDrbgContext, port: int, networkData: NetworkInitData
): BeaconNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = BeaconDb.new(networkData, "", inMemory = true)
    streamManager = StreamManager.new(node)
    network = BeaconNetwork.new(node, db, streamManager, networkData.forks)

  return BeaconNode(discoveryProtocol: node, beaconNetwork: network)

func portalProtocol*(n: BeaconNode): PortalProtocol =
  n.beaconNetwork.portalProtocol

func localNode*(n: BeaconNode): Node =
  n.discoveryProtocol.localNode

proc start*(n: BeaconNode) =
  n.beaconNetwork.start()

proc stop*(n: BeaconNode) {.async.} =
  n.beaconNetwork.stop()
  await n.discoveryProtocol.closeWait()

proc containsId*(n: BeaconNode, contentId: ContentId): bool =
  n.beaconNetwork.beaconDb.get(contentId).isSome()
