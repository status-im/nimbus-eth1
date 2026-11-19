# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  chronos,
  chronicles,
  beacon_chain/spec/[forks, network],
  ./types,
  ./engine

logScope:
  topics = "vp_beacon_frontend"

proc penalize[T](engine: RpcVerificationEngine, r: EngineResult[T]): EngineResult[T] =
  if r.isErr():
    engine.applyPenalty(r.error)
  r

proc getBeaconApiFrontend*(engine: RpcVerificationEngine): BeaconApiFrontend =
  let
    bootstrapProc = proc(
        blockRoot: Eth2Digest
    ): Future[EngineResult[ForkedLightClientBootstrap]] {.
        async: (raises: [CancelledError])
    .} =
      trace "Received query", meth = "getLightClientBootstrap", blockRoot
      let (backend, backendIdx) = ?engine.beaconBackendFor(BeaconBootstrap)
      return engine.penalize(
        (await backend.getLightClientBootstrap(blockRoot)).tagBackend(backendIdx)
      )

    updatesProc = proc(
        startPeriod: SyncCommitteePeriod, count: uint64
    ): Future[EngineResult[seq[ForkedLightClientUpdate]]] {.
        async: (raises: [CancelledError])
    .} =
      trace "Received query",
        meth = "getLightClientUpdatesByRange", startPeriod, count
      let
        (backend, backendIdx) = ?engine.beaconBackendFor(BeaconUpdates)
        cappedCount = min(count, MAX_REQUEST_LIGHT_CLIENT_UPDATES)
      return engine.penalize(
        (await backend.getLightClientUpdatesByRange(startPeriod, cappedCount)).tagBackend(
          backendIdx
        )
      )

    finalityProc = proc(): Future[EngineResult[ForkedLightClientFinalityUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      trace "Received query", meth = "getLightClientFinalityUpdate"
      let (backend, backendIdx) = ?engine.beaconBackendFor(BeaconFinality)
      return engine.penalize(
        (await backend.getLightClientFinalityUpdate()).tagBackend(backendIdx)
      )

    optimisticProc = proc(): Future[
        EngineResult[ForkedLightClientOptimisticUpdate]
    ] {.async: (raises: [CancelledError]).} =
      trace "Received query", meth = "getLightClientOptimisticUpdate"
      let (backend, backendIdx) = ?engine.beaconBackendFor(BeaconOptimistic)
      return engine.penalize(
        (await backend.getLightClientOptimisticUpdate()).tagBackend(backendIdx)
      )

  BeaconApiFrontend(
    getLightClientBootstrap: bootstrapProc,
    getLightClientUpdatesByRange: updatesProc,
    getLightClientFinalityUpdate: finalityProc,
    getLightClientOptimisticUpdate: optimisticProc,
  )
