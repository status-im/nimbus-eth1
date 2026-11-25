# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push raises: [].}

import
  unittest2,
  chronos,
  stint,
  beacon_chain/spec/[forks, network],
  ../engine/engine,
  ../engine/beacon_frontend,
  ../engine/types,
  ./test_utils,
  ./test_api_backend

let beaconFrontendEngineConf = RpcVerificationEngineConf(
  chainId: 1.u256,
  trustedBlockRoot: TEST_TBR,
  maxBlockWalk: 1,
  headerStoreLen: 16,
  accountCacheLen: 1,
  codeCacheLen: 1,
  storageCacheLen: 1,
  parallelBlockDownloads: 2,
  syncHeaderStore: false,
  freezeAtSlot: TEST_LC_SLOT,
)

proc initFailingBeaconBackend(): BeaconApiBackend =
  BeaconApiBackend(
    getLightClientBootstrap: proc(
        blockRoot: Eth2Digest
    ): Future[EngineResult[ForkedLightClientBootstrap]] {.
        async: (raises: [CancelledError])
    .} =
      err((BackendFetchError, "simulated transport failure", UNTAGGED)),
    getLightClientUpdatesByRange: proc(
        startPeriod: SyncCommitteePeriod, count: uint64
    ): Future[EngineResult[seq[ForkedLightClientUpdate]]] {.
        async: (raises: [CancelledError])
    .} =
      err((BackendFetchError, "simulated transport failure", UNTAGGED)),
    getLightClientOptimisticUpdate: proc(): Future[
        EngineResult[ForkedLightClientOptimisticUpdate]
    ] {.async: (raises: [CancelledError]).} =
      err((BackendFetchError, "simulated transport failure", UNTAGGED)),
    getLightClientFinalityUpdate: proc(): Future[
        EngineResult[ForkedLightClientFinalityUpdate]
    ] {.async: (raises: [CancelledError]).} =
      err((BackendFetchError, "simulated transport failure", UNTAGGED)),
  )

proc initBeaconFrontendEngine(): RpcVerificationEngine =
  RpcVerificationEngine.init(beaconFrontendEngineConf).valueOr:
    raiseAssert "engine init failed: " & error.errMsg

suite "beacon frontend passthrough":
  test "serves light client data without a synced light client":
    let
      ts = TestApiState.init(1.u256)
      engine = initBeaconFrontendEngine()
    engine.setupTestBeacon(ts)
    let frontend = engine.getBeaconApiFrontend()

    let
      bootstrap = waitFor frontend.getLightClientBootstrap(TEST_TBR)
      updates = waitFor frontend.getLightClientUpdatesByRange(
        TEST_LC_SLOT.sync_committee_period, 1
      )
      finality = waitFor frontend.getLightClientFinalityUpdate()
      optimistic = waitFor frontend.getLightClientOptimisticUpdate()

    check:
      not engine.isSynced()
      bootstrap.isOk()
      bootstrap.get().kind > LightClientDataFork.None
      updates.isOk()
      updates.get().len == 1
      finality.isOk()
      optimistic.isOk()
      engine.scores[0].availability > 0
      engine.scores[0].quality >= 0

  test "availability penalty on transport failure":
    let engine = initBeaconFrontendEngine()
    engine.registerBackend(initFailingBeaconBackend(), fullBeaconCapabilities)
    let frontend = engine.getBeaconApiFrontend()

    let res = waitFor frontend.getLightClientFinalityUpdate()

    check:
      res.isErr()
      res.error.errType == BackendFetchError
      res.error.backendIdx == 0
      engine.scores[0].availability < 0
      engine.scores[0].quality == 0

  test "penalized backend is skipped in favour of a healthy one":
    let
      ts = TestApiState.init(1.u256)
      engine = initBeaconFrontendEngine()
    engine.registerBackend(initFailingBeaconBackend(), fullBeaconCapabilities)
    engine.setupTestBeacon(ts)
    let frontend = engine.getBeaconApiFrontend()

    var successes, failures: int
    for _ in 0 ..< 20:
      let res = waitFor frontend.getLightClientOptimisticUpdate()
      if res.isOk():
        inc successes
      else:
        check res.error.backendIdx == 0
        inc failures

    check:
      failures <= 4
      successes >= 16

  test "updates count is capped":
    var requestedCount: uint64
    let engine = initBeaconFrontendEngine()
    var backend = initFailingBeaconBackend()
    backend.getLightClientUpdatesByRange = proc(
        startPeriod: SyncCommitteePeriod, count: uint64
    ): Future[EngineResult[seq[ForkedLightClientUpdate]]] {.
        async: (raises: [CancelledError])
    .} =
      requestedCount = count
      ok(newSeq[ForkedLightClientUpdate]())
    engine.registerBackend(backend, fullBeaconCapabilities)
    let frontend = engine.getBeaconApiFrontend()

    let res = waitFor frontend.getLightClientUpdatesByRange(SyncCommitteePeriod(0), 1000)

    check:
      res.isOk()
      requestedCount == MAX_REQUEST_LIGHT_CLIENT_UPDATES
