# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  chronos,
  chronicles,
  eth/common/keys,
  eth/net/nat,
  eth/enr/enr,
  beacon_chain/beacon_clock,
  beacon_chain/networking/[eth2_network, eth2_discovery, network_metadata],
  beacon_chain/conf_light_client,
  beacon_chain/sync/light_client_protocol,
  beacon_chain/spec/[forks, presets, column_map],
  beacon_chain/spec/datatypes/fulu,
  ./engine/types

logScope:
  topics = "P2PLightClientBackend"

type
  P2PBackendConf* = object
    cfg*: RuntimeConfig
    forkDigests*: ref ForkDigests
    getBeaconTime*: GetBeaconTimeFn
    genesisValidatorsRoot*: Eth2Digest
    genesisBlockRoot*: Eth2Digest
    tcpPort*: Port
    udpPort*: Port
    maxPeers*: int
    bootstrapNodesFile*: string
    nat*: string
    network*: string

  P2PLightClientBackend* = ref object
    network: Eth2Node

# FIXME: Weird, because this doesn't work if directly called from within init
proc registerPeerSyncProtocol(
    node: Eth2Node,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
    genesisBlockRoot: Eth2Digest,
    getBeaconTime: GetBeaconTimeFn,
) =
  node.registerProtocol(
    PeerSync,
    PeerSync.NetworkState.init(cfg, forkDigests, genesisBlockRoot, getBeaconTime),
  )

proc init*(T: type P2PLightClientBackend, conf: P2PBackendConf): EngineResult[T] =
  let natConfig =
    try:
      parseCmdArg(NatConfig, conf.nat)
    except ValueError as e:
      return err((BackendError, "invalid p2p-nat: " & e.msg, UNTAGGED))

  var lcConf = LightClientConf()
  lcConf.tcpPort = conf.tcpPort
  lcConf.udpPort = conf.udpPort
  lcConf.maxPeers = conf.maxPeers
  lcConf.tcpEnabled = true
  lcConf.agentString = "nimbus-verified-proxy"
  lcConf.nat = natConfig
  lcConf.discv5Enabled = true
  lcConf.enrAutoUpdate = true

  var fileEnrs: seq[enr.Record]
  loadBootstrapFile(conf.bootstrapNodesFile, fileEnrs)

  for r in fileEnrs:
    lcConf.bootstrapNodes.add r.toURI()

  if lcConf.bootstrapNodes.len == 0:
    lcConf.bootstrapNodes = getMetadataForNetwork(conf.network).bootstrapNodes

  let
    rng = keys.newRng()
    netKeys = rng[].getRandomNetKeys()
    eth2Node = createEth2Node(
      rng, lcConf, netKeys, conf.cfg, conf.forkDigests, conf.getBeaconTime,
      conf.genesisValidatorsRoot,
    ).valueOr:
      return err((BackendError, error, UNTAGGED))

  registerPeerSyncProtocol(
    eth2Node, conf.cfg, conf.forkDigests, conf.genesisBlockRoot, conf.getBeaconTime
  )

  # FIXME: This is weird, should be automatically defined to default
  eth2Node.loadCgcnetMetadataAndEnr(
    CgcCount(conf.cfg.CUSTODY_REQUIREMENT), not (default(ColumnMap))
  )

  ok(T(network: eth2Node))

proc start*(
    backend: P2PLightClientBackend
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  try:
    await backend.network.startListening()
    await backend.network.start()
    ok()
  except CancelledError as e:
    raise e
  except CatchableError as e:
    err((BackendError, e.msg, UNTAGGED))

proc stop*(backend: P2PLightClientBackend) {.async: (raises: []).} =
  await noCancel backend.network.stop()

proc getBeaconApiBackend*(backend: P2PLightClientBackend): BeaconApiBackend =
  let
    getLCBootstrapProc = proc(
        blockRoot: Eth2Digest
    ): Future[EngineResult[ForkedLightClientBootstrap]] {.
        async: (raises: [CancelledError])
    .} =
      var peer: Peer
      try:
        peer = backend.network.peerPool.acquireNoWait()
        let res = await peer.lightClientBootstrap(blockRoot)
        if res.isErr():
          return err((BackendFetchError, $res.error(), UNTAGGED))
        ok(res.value())
      except PeerPoolError as e:
        err((BackendFetchError, e.msg, UNTAGGED))
      except CancelledError as e:
        raise e
      finally:
        if peer != nil:
          backend.network.peerPool.release(peer)

    getLCUpdatesProc = proc(
        startPeriod: SyncCommitteePeriod, count: uint64
    ): Future[EngineResult[seq[ForkedLightClientUpdate]]] {.
        async: (raises: [CancelledError])
    .} =
      var peer: Peer
      try:
        peer = backend.network.peerPool.acquireNoWait()
        let res = await peer.lightClientUpdatesByRange(startPeriod, count)
        if res.isErr():
          return err((BackendFetchError, $res.error(), UNTAGGED))
        ok(seq[ForkedLightClientUpdate](res.value()))
      except PeerPoolError as e:
        err((BackendFetchError, e.msg, UNTAGGED))
      except CancelledError as e:
        raise e
      finally:
        if peer != nil:
          backend.network.peerPool.release(peer)

    getLCFinalityProc = proc(): Future[EngineResult[ForkedLightClientFinalityUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      var peer: Peer
      try:
        peer = backend.network.peerPool.acquireNoWait()
        let res = await peer.lightClientFinalityUpdate()
        if res.isErr():
          return err((BackendFetchError, $res.error(), UNTAGGED))
        ok(res.value())
      except PeerPoolError as e:
        err((BackendFetchError, e.msg, UNTAGGED))
      except CancelledError as e:
        raise e
      finally:
        if peer != nil:
          backend.network.peerPool.release(peer)

    getLCOptimisticProc = proc(): Future[
        EngineResult[ForkedLightClientOptimisticUpdate]
    ] {.async: (raises: [CancelledError]).} =
      var peer: Peer
      try:
        peer = backend.network.peerPool.acquireNoWait()
        let res = await peer.lightClientOptimisticUpdate()
        if res.isErr():
          return err((BackendFetchError, $res.error(), UNTAGGED))
        ok(res.value())
      except PeerPoolError as e:
        err((BackendFetchError, e.msg, UNTAGGED))
      except CancelledError as e:
        raise e
      finally:
        if peer != nil:
          backend.network.peerPool.release(peer)

  BeaconApiBackend(
    getLightClientBootstrap: getLCBootstrapProc,
    getLightClientUpdatesByRange: getLCUpdatesProc,
    getLightClientFinalityUpdate: getLCFinalityProc,
    getLightClientOptimisticUpdate: getLCOptimisticProc,
  )
