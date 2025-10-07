# Nimbus - Portal Network
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  beacon_chain/spec/forks,
  ../../network/wire/[portal_protocol, portal_protocol_config, portal_stream],
  ../../network/beacon/[beacon_init_loader, beacon_network],
  ../test_helpers

type BeaconNode* = ref object
  discv5*: discv5_protocol.Protocol
  beaconNetwork*: BeaconNetwork

proc newLCNode*(
    rng: ref HmacDrbgContext,
    port: int,
    networkData: NetworkInitData,
    trustedBlockRoot: Opt[Digest] = Opt.none(Digest),
): BeaconNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = BeaconDb.new(networkData, "", inMemory = true)
    streamManager = StreamManager.new(node)
    network = BeaconNetwork.new(
      PortalNetwork.mainnet,
      node,
      db,
      streamManager,
      networkData.forks,
      networkData.clock.getBeaconTimeFn(),
      networkData.metadata.cfg,
      trustedBlockRoot,
    )

  return BeaconNode(discv5: node, beaconNetwork: network)

func portalProtocol*(n: BeaconNode): PortalProtocol =
  n.beaconNetwork.portalProtocol

func localNode*(n: BeaconNode): Node =
  n.discv5.localNode

proc start*(n: BeaconNode) =
  n.beaconNetwork.start()

proc stop*(n: BeaconNode) {.async.} =
  discard n.beaconNetwork.stop()
  await n.discv5.closeWait()

proc containsId*(n: BeaconNode, contentId: ContentId): bool =
  n.beaconNetwork.beaconDb.get(contentId).isSome()
