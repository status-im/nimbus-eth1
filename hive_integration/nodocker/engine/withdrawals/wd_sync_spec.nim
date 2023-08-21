import
  chronicles,
  ./wd_base_spec,
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

proc execute*(ws: SyncSpec, t: TestEnv): bool =
  # Do the base withdrawal test first, skipping base verifications
  WDBaseSpec(ws).skipBaseVerifications = true
  testCond WDBaseSpec(ws).execute(t)

#[
  # Spawn a secondary client which will need to sync to the primary client
  secondaryEngine, err := hive_rpc.HiveRPCEngineStarter{}.StartClient(t.T, t.TestContext, t.Genesis, t.ClientParams, t.ClientFiles, t.Engine)
  if err != nil {
    error "Unable to spawn a secondary client: %v", t.TestName, err)

  secondaryEngineTest := test.NewTestEngineClient(t, secondaryEngine)
  t.clMock.AddEngineClient(secondaryEngine)

  if ws.SyncSteps > 1 {
    # TODO
  else:
    # Send the FCU to trigger sync on the secondary client
  loop:
    for {
      select {
      case <-t.TimeoutContext.Done():
        error "Timeout while waiting for secondary client to sync", t.TestName)
      case <-time.After(time.Second):
        secondaryEngineTest.TestEngineNewPayloadV2(
          &t.clMock.latestExecutedPayload,
        r := secondaryEngineTest.TestEngineForkchoiceUpdatedV2(
          &t.clMock.latestForkchoice,
          nil,
        if r.Response.PayloadStatus.Status == test.Valid {
          break loop
        if r.Response.PayloadStatus.Status == test.Invalid {
          error "Syncing client rejected valid chain: %s", t.TestName, r.Response)

  ws.wdHistory.VerifyWithdrawals(t.clMock.latestHeader.Number.Uint64(), nil, secondaryEngineTest)
]#
  return true
