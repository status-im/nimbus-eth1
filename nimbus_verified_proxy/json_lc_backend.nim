# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  stint,
  chronos,
  chronicles,
  presto/client,
  beacon_chain/spec/eth2_apis/rest_light_client_calls,
  beacon_chain/spec/presets,
  beacon_chain/spec/forks,
  ./lc/lc_manager,
  ./nimbus_verified_proxy_conf

logScope:
  topics = "SSZLCRestClient"

const
  MaxMessageBodyBytes* = 128 * 1024 * 1024 # 128 MB (JSON encoded)
  BASE_URL = "/eth/v1/beacon/light_client"

type
  LCRestPeer = ref object
    score: int
    restClient: RestClientRef

  LCRestClient* = ref object
    cfg: RuntimeConfig
    forkDigests: ref ForkDigests
    peers: seq[LCRestPeer]
    urls: seq[string]

func new*(
    T: type LCRestClient, cfg: RuntimeConfig, forkDigests: ref ForkDigests
): LCRestClient =
  LCRestClient(cfg: cfg, forkDigests: forkDigests, peers: @[])

proc addEndpoints*(client: LCRestClient, urlList: UrlList) {.raises: [ValueError].} =
  for endpoint in urlList.urls:
    if endpoint in client.urls:
      continue

    let restClient = RestClientRef.new(endpoint).valueOr:
      raise newException(ValueError, $error)

    client.peers.add(LCRestPeer(score: 0, restClient: restClient))
    client.urls.add(endpoint)

proc closeAll*(client: LCRestClient) {.async: (raises: []).} =
  for peer in client.peers:
    await peer.restClient.closeWait()

  client.peers.setLen(0)
  client.urls.setLen(0)

proc getEthLCBackend*(client: LCRestClient): EthLCBackend =
  let
    getLCBootstrapProc = proc(
        reqId: uint64, blockRoot: Eth2Digest
    ): Future[NetRes[ForkedLightClientBootstrap]] {.async: (raises: [CancelledError]).} =
      let
        peer = client.peers[reqId mod uint64(client.peers.len)]
        res =
          try:
            await peer.restClient.getLightClientBootstrap(
              blockRoot, client.cfg, client.forkDigests
            )
          except CatchableError as e:
            raise newException(CancelledError, e.msg)

      ok(res)

    getLCUpdatesProc = proc(
        reqId: uint64, startPeriod: SyncCommitteePeriod, count: uint64
    ): Future[LightClientUpdatesByRangeResponse] {.async: (raises: [CancelledError]).} =
      let
        peer = client.peers[reqId mod uint64(client.peers.len)]
        res =
          try:
            await peer.restClient.getLightClientUpdatesByRange(
              startPeriod, count, client.cfg, client.forkDigests
            )
          except CatchableError as e:
            raise newException(CancelledError, e.msg)

      ok(res)

    getLCFinalityProc = proc(
        reqId: uint64
    ): Future[NetRes[ForkedLightClientFinalityUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      let
        peer = client.peers[reqId mod uint64(client.peers.len)]
        res =
          try:
            await peer.restClient.getLightClientFinalityUpdate(
              client.cfg, client.forkDigests
            )
          except CatchableError as e:
            raise newException(CancelledError, e.msg)

      ok(res)

    getLCOptimisticProc = proc(
        reqId: uint64
    ): Future[NetRes[ForkedLightClientOptimisticUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      let
        peer = client.peers[reqId mod uint64(client.peers.len)]
        res =
          try:
            await peer.restClient.getLightClientOptimisticUpdate(
              client.cfg, client.forkDigests
            )
          except CatchableError as e:
            raise newException(CancelledError, e.msg)

      ok(res)

    updateScoreProc = proc(reqId: uint64, value: int) =
      let peer = client.peers[reqId mod uint64(client.peers.len)]
      peer.score += value

  EthLCBackend(
    getLightClientBootstrap: getLCBootstrapProc,
    getLightClientUpdatesByRange: getLCUpdatesProc,
    getLightClientFinalityUpdate: getLCFinalityProc,
    getLightClientOptimisticUpdate: getLCOptimisticProc,
    updateScore: updateScoreProc,
  )
