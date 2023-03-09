# Nimbus - Portal Network
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  beacon_chain/spec/forks,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/beacon_light_client/[
    light_client_network,
    light_client_db
  ],
  ../test_helpers

type LightClientNode* = ref object
  discoveryProtocol*: discv5_protocol.Protocol
  lightClientNetwork*: LightClientNetwork

const testForkDigests* =
  ForkDigests(
    phase0: ForkDigest([0'u8, 0, 0, 1]),
    altair: ForkDigest([0'u8, 0, 0, 2]),
    bellatrix: ForkDigest([0'u8, 0, 0, 3]),
    capella: ForkDigest([0'u8, 0, 0, 4]),
    eip4844: ForkDigest([0'u8, 0, 0, 5])
  )

proc newLCNode*(
    rng: ref HmacDrbgContext,
    port: int,
    forkDigests: ForkDigests = testForkDigests): LightClientNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = LightClientDb.new("", inMemory = true)
    streamManager = StreamManager.new(node)
    network = LightClientNetwork.new(node, db, streamManager, forkDigests)

  return LightClientNode(discoveryProtocol: node, lightClientNetwork: network)

func portalProtocol*(n: LightClientNode): PortalProtocol =
  n.lightClientNetwork.portalProtocol

func localNode*(n: LightClientNode): Node =
  n.discoveryProtocol.localNode

proc start*(n: LightClientNode) =
  n.lightClientNetwork.start()

proc stop*(n: LightClientNode) {.async.} =
  n.lightClientNetwork.stop()
  await n.discoveryProtocol.closeWait()

proc containsId*(n: LightClientNode, contentId: ContentId): bool =
  n.lightClientNetwork.lightClientDb.get(contentId).isSome()
