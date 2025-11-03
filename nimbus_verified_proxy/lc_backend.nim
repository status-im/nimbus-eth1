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
  topics = "LCRestClientPool"

const
  MaxMessageBodyBytes* = 128 * 1024 * 1024 # 128 MB (JSON encoded)
  BASE_URL = "/eth/v1/beacon/light_client"

type
  LCRestClient = ref object
    score: int
    restClient: RestClientRef

  LCRestClientPool* = ref object
    cfg: RuntimeConfig
    forkDigests: ref ForkDigests
    clients: seq[LCRestClient]
    idMap: Table[uint64, LCRestClient]
    urls: seq[string]

func new*(
    T: type LCRestClientPool, cfg: RuntimeConfig, forkDigests: ref ForkDigests
): LCRestClientPool =
  LCRestClientPool(cfg: cfg, forkDigests: forkDigests, clients: @[])

proc addEndpoints*(pool: LCRestClientPool, urlList: UrlList) {.raises: [ValueError].} =
  for endpoint in urlList.urls:
    if endpoint in pool.urls:
      continue

    let restClient = RestClientRef.new(endpoint).valueOr:
      raise newException(ValueError, $error)

    pool.clients.add(LCRestClient(score: 0, restClient: restClient))
    pool.urls.add(endpoint)

proc closeAll*(pool: LCRestClientPool) {.async: (raises: []).} =
  for client in pool.clients:
    await client.restClient.closeWait()

  pool.clients.setLen(0)
  pool.urls.setLen(0)

proc getClientForReqId(pool: LCRestClientPool, reqId: uint64): LCRestClient =
  if pool.idMap.contains(reqId):
    return pool.idMap.getOrDefault(reqId)

  let client = pool.clients[reqId mod pool.clients.lenu64]
  pool.idMap[reqId] = client

  client

proc getEthLCBackend*(pool: LCRestClientPool): EthLCBackend =
  let
    getLCBootstrapProc = proc(
        reqId: uint64, blockRoot: Eth2Digest
    ): Future[NetRes[ForkedLightClientBootstrap]] {.async: (raises: [CancelledError]).} =
      let
        client = pool.getClientForReqId(reqId)
        res =
          try:
            await client.restClient.getLightClientBootstrap(
              blockRoot, pool.cfg, pool.forkDigests
            )
          except CancelledError as e:
            raise e
          except CatchableError as e:
            return err()

      ok(res)

    getLCUpdatesProc = proc(
        reqId: uint64, startPeriod: SyncCommitteePeriod, count: uint64
    ): Future[LightClientUpdatesByRangeResponse] {.async: (raises: [CancelledError]).} =
      let
        client = pool.getClientForReqId(reqId)
        res =
          try:
            await client.restClient.getLightClientUpdatesByRange(
              startPeriod, count, pool.cfg, pool.forkDigests
            )
          except CancelledError as e:
            raise e
          except CatchableError as e:
            return err()

      ok(res)

    getLCFinalityProc = proc(
        reqId: uint64
    ): Future[NetRes[ForkedLightClientFinalityUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      let
        client = pool.getClientForReqId(reqId)
        res =
          try:
            await client.restClient.getLightClientFinalityUpdate(
              pool.cfg, pool.forkDigests
            )
          except CancelledError as e:
            raise e
          except CatchableError as e:
            return err()

      ok(res)

    getLCOptimisticProc = proc(
        reqId: uint64
    ): Future[NetRes[ForkedLightClientOptimisticUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      let
        client = pool.getClientForReqId(reqId)
        res =
          try:
            await client.restClient.getLightClientOptimisticUpdate(
              pool.cfg, pool.forkDigests
            )
          except CancelledError as e:
            raise e
          except CatchableError as e:
            return err()

      ok(res)

    updateScoreProc = proc(reqId: uint64, value: int) =
      let client = pool.getClientForReqId(reqId)
      client.score += value

      pool.idMap.del(reqId)

  EthLCBackend(
    getLightClientBootstrap: getLCBootstrapProc,
    getLightClientUpdatesByRange: getLCUpdatesProc,
    getLightClientFinalityUpdate: getLCFinalityProc,
    getLightClientOptimisticUpdate: getLCOptimisticProc,
    updateScore: updateScoreProc,
  )
