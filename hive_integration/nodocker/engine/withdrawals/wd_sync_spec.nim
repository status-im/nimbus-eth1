# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  chronicles,
  json_rpc/rpcclient,
  ./wd_base_spec,
  ./wd_history,
  ../test_env,
  ../engine_client,
  ../types

# Withdrawals sync spec:
# Specifies a withdrawals test where the withdrawals happen and then a
# client needs to sync and apply the withdrawals.
type
  SyncSpec* = ref object of WDBaseSpec
    syncSteps*: int  # Sync block chunks that will be passed as head through FCUs to the syncing client
    syncShouldFail*: bool
    sleep*: int

proc doSync(ws: SyncSpec, client: RpcClient, clMock: CLMocker): Future[bool] {.async.} =
  if ws.sleep == 0:
    ws.sleep = DefaultSleep
  let period = chronos.seconds(ws.sleep)
  var loop = 0
  if ws.timeoutSeconds == 0:
    ws.timeoutSeconds = DefaultTimeout

  while loop < ws.timeoutSeconds:
    let res = client.newPayloadV2(clMock.latestExecutedPayload.V1V2)
    discard res

    let r = client.forkchoiceUpdatedV2(clMock.latestForkchoice)
    if r.isErr:
      error "fcu error", msg=r.error
      return false

    let s = r.get
    if s.payloadStatus.status == PayloadExecutionStatus.valid:
      return true

    if s.payloadStatus.status == PayloadExecutionStatus.invalid:
      error "Syncing client rejected valid chain"

    await sleepAsync(period)
    loop += ws.sleep

  return false

proc execute*(ws: SyncSpec, env: TestEnv): bool =
  # Do the base withdrawal test first, skipping base verifications
  WDBaseSpec(ws).skipBaseVerifications = true
  testCond WDBaseSpec(ws).execute(env)

  # Spawn a secondary client which will need to sync to the primary client
  let sec = env.addEngine()

  if ws.syncSteps > 1:
    # TODO
    discard
  else:
    # Send the FCU to trigger sync on the secondary client
    let ok = waitFor doSync(ws, sec.client, env.clMock)
    if not ok:
      return false

  let bn = env.clMock.latestHeader.number
  let res = ws.wdHistory.verifyWithdrawals(bn, Opt.none(uint64), sec.client)
  if res.isErr:
    error "wd history error", msg=res.error
    return false

  return true
