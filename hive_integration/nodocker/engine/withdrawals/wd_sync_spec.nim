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
    timeoutSeconds*: int

proc doSync(ws: SyncSpec, client: RpcClient, clMock: CLMocker): Future[bool] {.async.} =
  let period = chronos.seconds(1)
  var loop = 0
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
    inc loop

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

  let bn = env.clMock.latestHeader.blockNumber.truncate(uint64)
  let res = ws.wdHistory.verifyWithdrawals(bn, none(UInt256), sec.client)
  if res.isErr:
    error "wd history error", msg=res.error
    return false

  return true
