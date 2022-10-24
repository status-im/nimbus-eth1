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
  eth/common/eth_types_rlp,
  eth/rlp,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  ../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../network/beacon_light_client/[light_client_network, light_client_content],
  ../../nimbus/constants,
  ../content_db,
  ./test_helpers,
  ./light_client_data/light_client_test_data

type LightClientNode = ref object
  discoveryProtocol*: discv5_protocol.Protocol
  lightClientNetwork*: LightClientNetwork

proc getTestForkDigests(): ForkDigests =
  return ForkDigests(
    phase0: ForkDigest([0'u8, 0, 0, 1]),
    altair: ForkDigest([0'u8, 0, 0, 2]),
    bellatrix: ForkDigest([0'u8, 0, 0, 3]),
    capella: ForkDigest([0'u8, 0, 0, 4]),
    sharding: ForkDigest([0'u8, 0, 0, 5])
  )

proc newLCNode(rng: ref HmacDrbgContext, port: int): LightClientNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new("", uint32.high, inMemory = true)
    streamManager = StreamManager.new(node)
    hn = LightClientNetwork.new(node, db, streamManager, getTestForkDigests())

  return LightClientNode(discoveryProtocol: node, lightClientNetwork: hn)

proc portalProtocol(hn: LightClientNode): PortalProtocol =
  hn.lightClientNetwork.portalProtocol

proc localNode(hn: LightClientNode): Node =
  hn.discoveryProtocol.localNode

proc start(hn: LightClientNode) =
  hn.lightClientNetwork.start()

proc stop(hn: LightClientNode) {.async.} =
  hn.lightClientNetwork.stop()
  await hn.discoveryProtocol.closeWait()

proc containsId(hn: LightClientNode, contentId: ContentId): bool =
  return hn.lightClientNetwork.contentDB.get(contentId).isSome()

procSuite "Light client Content Network":
  let rng = newRng()

  asyncTest "Get bootstrap by trusted block hash":
    let
      lcNode1 = newLCNode(rng, 20302)
      lcNode2 = newLCNode(rng, 20303)
      forks = getTestForkDigests()

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      bootstrap = SSZ.decode(bootstrapBytes, altair.LightClientBootstrap)
      bootstrappHeaderHash = hash_tree_root(bootstrap.header)
      bootstrapKey = LightClientBootstrapKey(
        blockHash: bootstrappHeaderHash
      )
      bootstrapContentKey = ContentKey(
        contentType: lightClientBootstrap,
        lightClientBootstrapKey: bootstrapKey
      )

      bootstrapContentKeyEncoded = encode(bootstrapContentKey)
      bootstrapContentId = toContentId(bootstrapContentKeyEncoded)

    lcNode2.portalProtocol().storeContent(
      bootstrapContentId, encodeBootstrapForked(forks.altair, bootstrap)
    )

    let bootstrapFromNetworkResult =
      await lcNode1.lightClientNetwork.getLightClientBootstrap(
        bootstrappHeaderHash
      )

    check:
      bootstrapFromNetworkResult.isOk()
      bootstrapFromNetworkResult.get() == bootstrap

    await lcNode1.stop()
    await lcNode2.stop()
