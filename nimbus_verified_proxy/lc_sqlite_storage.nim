# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  results,
  chronos,
  beacon_chain/spec/forks,
  beacon_chain/light_client_db,
  ./engine/types

export light_client_db

proc getLightClientStorage*(db: LightClientDB): LightClientStorage =
  let
    loadProc = proc(): Future[EngineResult[Opt[LightClientCheckpoint]]] {.
        async: (raises: [CancelledError])
    .} =
      let header = db.getLatestFinalizedHeader()
      withForkyHeader(header):
        when lcDataFork > LightClientDataFork.None:
          let syncCommittee = db.getSyncCommittee(
            forkyHeader.beacon.slot.sync_committee_period
          ).valueOr:
            return err((UnavailableDataError, "LC store lacks sync committee", UNTAGGED))
          return ok(
            Opt.some(LightClientCheckpoint(header: header, syncCommittee: syncCommittee))
          )
        else:
          return ok(Opt.none(LightClientCheckpoint))

    saveProc = proc(
        cp: LightClientCheckpoint
    ): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
      withForkyHeader(cp.header):
        when lcDataFork > LightClientDataFork.None:
          db.putSyncCommittee(
            forkyHeader.beacon.slot.sync_committee_period, cp.syncCommittee
          )
          db.putLatestFinalizedHeader(cp.header)
          return ok()
        else:
          return err((UnavailableDataError, "cannot store an empty LC header", UNTAGGED))

  LightClientStorage(load: loadProc, save: saveProc)
