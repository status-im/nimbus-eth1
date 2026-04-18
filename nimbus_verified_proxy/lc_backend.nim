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
  presto/client,
  beacon_chain/spec/eth2_apis/rest_light_client_calls,
  beacon_chain/spec/presets,
  beacon_chain/spec/forks,
  ./engine/types

logScope:
  topics = "BeaconApiRestClient"

const
  MaxMessageBodyBytes* = 128 * 1024 * 1024 # 128 MB (JSON encoded)
  BASE_URL = "/eth/v1/beacon/light_client"

type BeaconApiRestClient* = ref object
  cfg: RuntimeConfig
  forkDigests: ref ForkDigests
  client: RestClientRef
  url: string

func init*(
    T: type BeaconApiRestClient,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
    url: string,
): BeaconApiRestClient =
  BeaconApiRestClient(cfg: cfg, forkDigests: forkDigests, url: url)

proc start*(backend: BeaconApiRestClient): EngineResult[void] =
  backend.client = RestClientRef.new(backend.url).valueOr:
    return err((BackendError, $error, UNTAGGED))

  ok()

proc stop*(backend: BeaconApiRestClient) {.async: (raises: []).} =
  await backend.client.closeWait()

proc getBeaconApiBackend*(backend: BeaconApiRestClient): BeaconApiBackend =
  let
    getLCBootstrapProc = proc(
        blockRoot: Eth2Digest
    ): Future[EngineResult[ForkedLightClientBootstrap]] {.
        async: (raises: [CancelledError])
    .} =
      try:
        ok(
          await backend.client.getLightClientBootstrap(
            blockRoot, backend.cfg, backend.forkDigests
          )
        )
      except CancelledError as e:
        raise e
      except CatchableError as e:
        err((BackendFetchError, e.msg, UNTAGGED))

    getLCUpdatesProc = proc(
        startPeriod: SyncCommitteePeriod, count: uint64
    ): Future[EngineResult[seq[ForkedLightClientUpdate]]] {.
        async: (raises: [CancelledError])
    .} =
      try:
        ok(
          await backend.client.getLightClientUpdatesByRange(
            startPeriod, count, backend.cfg, backend.forkDigests
          )
        )
      except CancelledError as e:
        raise e
      except CatchableError as e:
        err((BackendFetchError, e.msg, UNTAGGED))

    getLCFinalityProc = proc(): Future[EngineResult[ForkedLightClientFinalityUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      try:
        ok(
          await backend.client.getLightClientFinalityUpdate(
            backend.cfg, backend.forkDigests
          )
        )
      except CancelledError as e:
        raise e
      except CatchableError as e:
        err((BackendFetchError, e.msg, UNTAGGED))

    getLCOptimisticProc = proc(): Future[
        EngineResult[ForkedLightClientOptimisticUpdate]
    ] {.async: (raises: [CancelledError]).} =
      try:
        ok(
          await backend.client.getLightClientOptimisticUpdate(
            backend.cfg, backend.forkDigests
          )
        )
      except CancelledError as e:
        raise e
      except CatchableError as e:
        err((BackendFetchError, e.msg, UNTAGGED))

  BeaconApiBackend(
    getLightClientBootstrap: getLCBootstrapProc,
    getLightClientUpdatesByRange: getLCUpdatesProc,
    getLightClientFinalityUpdate: getLCFinalityProc,
    getLightClientOptimisticUpdate: getLCOptimisticProc,
  )
