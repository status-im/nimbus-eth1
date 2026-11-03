# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/options,
  unittest2,
  chronos,
  stint,
  beacon_chain/spec/forks,
  ../engine/types,
  ../engine/engine,
  ../engine/lc_storage,
  ../library/c_storage,
  ./test_utils,
  ./test_api_backend

type MemoryCheckpoint = ref object
  cp: Opt[LightClientCheckpoint]
  saves: int

proc memoryStorage(m: MemoryCheckpoint): LightClientStorage =
  LightClientStorage(
    load: proc(): Future[EngineResult[Opt[LightClientCheckpoint]]] {.
        async: (raises: [CancelledError])
    .} =
      ok(m.cp),
    save: proc(
        cp: LightClientCheckpoint
    ): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
      m.cp = Opt.some(cp)
      inc m.saves
      ok(),
  )

proc newStorageTestEngine(
    testState: TestApiState,
    trustedBlockRoot: Option[Eth2Digest],
    freezeAtSlot: Slot,
    m: MemoryCheckpoint,
): RpcVerificationEngine =
  let engine = RpcVerificationEngine
    .init(
      RpcVerificationEngineConf(
        chainId: 1.u256,
        trustedBlockRoot: trustedBlockRoot,
        maxBlockWalk: 1,
        headerStoreLen: 16,
        accountCacheLen: 1,
        codeCacheLen: 1,
        storageCacheLen: 1,
        parallelBlockDownloads: 2,
        maxLightClientUpdates: 128,
        syncHeaderStore: false,
        freezeAtSlot: freezeAtSlot,
      )
    )
    .expect("engine init")
  engine.storage = Opt.some(memoryStorage(m))
  engine.setupTestBeacon(testState)
  engine

func checkpointSlot(cp: LightClientCheckpoint): Slot =
  withForkyHeader(cp.header):
    when lcDataFork > LightClientDataFork.None:
      forkyHeader.beacon.slot
    else:
      GENESIS_SLOT

suite "light client checkpoint storage":
  let
    testState = TestApiState.init(1.u256)
    m = MemoryCheckpoint()

  test "isCheckpointStale at the weak subjectivity boundary":
    let
      engine = newStorageTestEngine(testState, some(TEST_TBR), TEST_LC_SLOT, m)
      maxPeriods = engine.cfg.defaultLightClientDataMaxPeriods()
      period = TEST_LC_SLOT.sync_committee_period
      checkpoint = period.start_slot

    check:
      not engine.cfg.isCheckpointStale(checkpoint, checkpoint)
      not engine.cfg.isCheckpointStale(checkpoint, (period + maxPeriods).start_slot)
      engine.cfg.isCheckpointStale(checkpoint, (period + maxPeriods + 1).start_slot)

  test "bootstrap persists a checkpoint":
    let engine = newStorageTestEngine(testState, some(TEST_TBR), TEST_LC_SLOT, m)

    check:
      (waitFor engine.syncOnce()).isOk()
      m.saves > 0
      m.cp.isSome()

  test "restore from storage without a trusted block root":
    let engine = newStorageTestEngine(testState, none(Eth2Digest), TEST_LC_SLOT, m)

    check:
      waitFor engine.restoreCheckpoint()
      (waitFor engine.syncOnce()).isOk()

  test "stale checkpoint is ignored":
    let
      maxPeriods = defaultRuntimeConfig.defaultLightClientDataMaxPeriods()
      staleSlot =
        (m.cp.get().checkpointSlot.sync_committee_period + maxPeriods + 1).start_slot
      engine = newStorageTestEngine(testState, none(Eth2Digest), staleSlot, m)

    check:
      not (waitFor engine.restoreCheckpoint())
      (waitFor engine.syncOnce()).isErr()

  test "checkpoint encoding round trip":
    let
      bytes = encodeCheckpoint(m.cp.get())
      decoded = decodeCheckpoint(bytes).expect("valid checkpoint")

    check:
      decoded.checkpointSlot == m.cp.get().checkpointSlot
      encodeCheckpoint(decoded) == bytes
      decodeCheckpoint(bytes[0 ..< 10]).isErr()
      decodeCheckpoint(@[byte(0xff)] & bytes[1 .. ^1]).isErr()
