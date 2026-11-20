# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  results,
  chronicles,
  chronos,
  beacon_chain/spec/forks,
  beacon_chain/gossip_processing/light_client_processor,
  beacon_chain/beacon_clock,
  ./types

logScope:
  topics = "vp_engine"

func isCheckpointStale*(cfg: RuntimeConfig, checkpointSlot, currentSlot: Slot): bool =
  currentSlot.sync_committee_period >
    checkpointSlot.sync_committee_period + cfg.defaultLightClientDataMaxPeriods()

proc restoreCheckpoint*(
    engine: RpcVerificationEngine
): Future[bool] {.async: (raises: [CancelledError]).} =
  let storage = engine.storage.valueOr:
    return false

  let cp = (await storage.load()).valueOr:
    warn "Failed to load LC checkpoint from storage", err = error.errMsg
    return false

  if cp.isNone():
    debug "No LC checkpoint in storage"
    return false

  var checkpointSlot: Slot
  withForkyHeader(cp.get().header):
    when lcDataFork > LightClientDataFork.None:
      checkpointSlot = forkyHeader.beacon.slot
    else:
      warn "Stored LC checkpoint has an empty header"
      return false

  let currentSlot = engine.getBeaconTime().slotOrZero(engine.timeParams)
  if engine.cfg.isCheckpointStale(checkpointSlot, currentSlot):
    warn "Stored LC checkpoint is stale, ignoring it", checkpointSlot, currentSlot
    return false

  engine.lcProcessor[].resetToFinalizedHeader(cp.get().header, cp.get().syncCommittee)
  info "LC restored from storage", checkpointSlot
  true

proc persistCheckpoint*(
    engine: RpcVerificationEngine
) {.async: (raises: [CancelledError]).} =
  let storage = engine.storage.valueOr:
    return

  var
    cp: LightClientCheckpoint
    checkpointSlot: Slot
  withForkyStore(engine.lcStore[]):
    when lcDataFork > LightClientDataFork.None:
      cp = LightClientCheckpoint(
        header: ForkedLightClientHeader.init(forkyStore.finalized_header),
        syncCommittee: forkyStore.current_sync_committee,
      )
      checkpointSlot = forkyStore.finalized_header.beacon.slot
    else:
      return

  let res = await storage.save(cp)
  if res.isErr():
    warn "Failed to persist LC checkpoint", checkpointSlot, err = res.error.errMsg
  else:
    debug "Persisted LC checkpoint", checkpointSlot
