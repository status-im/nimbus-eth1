import
  chronos,
  ./wd_base_spec,
  ../test_env,
  ../engine_client,
  ../types

# Withdrawals sync spec:
# Specifies a withdrawals test where the withdrawals happen and then a
# client needs to sync and apply the withdrawals.
type
  GetPayloadBodyRequest = ref object of RootObj
    #Verify(int, *test.TestEngineClient, clmock.ExecutableDataHistory)

  GetPayloadBodyRequestByRange = ref object of GetPayloadBodyRequest
    Start uint64
    Count uint64

  GetPayloadBodyRequestByHashIndex = ref object of GetPayloadBodyRequest
    BlockNumbers []uint64
    Start        uint64
    End          uint64

  GetPayloadBodiesSpec* = ref object of WDBaseSpec
    getPayloadBodiesRequests: seq[GetPayloadBodyRequest]
    requestsRepeat          : int
    generateSidechain       : bool
    afterSync               : bool
    parallel                : bool

#[


func (req GetPayloadBodyRequestByRange) Verify(reqIndex int, testEngine *test.TestEngineClient, payloadHistory clmock.ExecutableDataHistory) {
  info "Starting GetPayloadBodyByRange request %d", reqIndex)
  startTime := time.Now()
  defer func() {
    info "Ended GetPayloadBodyByRange request %d, %s", reqIndex, time.Since(startTime))
  }()
  r := testEngine.getPayloadBodiesByRangeV1(req.Start, req.Count)
  if req.Start < 1 || req.Count < 1 {
    r.expectationDescription = fmt.Sprintf(`
      Sent start (%d) or count (%d) to engine_getPayloadBodiesByRangeV1 with a
      value less than 1, therefore error is expected.
      `, req.Start, req.Count)
    r.expectErrorCode(InvalidParamsError)
    return
  }
  latestPayloadNumber := payloadHistory.latestPayloadNumber()
  if req.Start > latestPayloadNumber {
    r.expectationDescription = fmt.Sprintf(`
      Sent start=%d and count=%d to engine_getPayloadBodiesByRangeV1, latest known block is %d, hence an empty list is expected.
      `, req.Start, req.Count, latestPayloadNumber)
    r.expectPayloadBodiesCount(0)
  } else {
    var count = req.Count
    if req.Start+req.Count-1 > latestPayloadNumber {
      count = latestPayloadNumber - req.Start + 1
    }
    r.expectationDescription = fmt.Sprintf("Sent engine_getPayloadBodiesByRange(start=%d, count=%d), latest payload number in canonical chain is %d", req.Start, req.Count, latestPayloadNumber)
    r.expectPayloadBodiesCount(count)
    for i := req.Start; i < req.Start+count; i++ {
      p := payloadHistory[i]

      r.expectPayloadBody(i-req.Start, ExecutionPayloadBodyV1{
        Transactions: p.Transactions,
        Withdrawals:  p.Withdrawals,
      })
    }
  }
}



func (req GetPayloadBodyRequestByHashIndex) Verify(reqIndex int, testEngine *test.TestEngineClient, payloadHistory clmock.ExecutableDataHistory) {
  info "Starting GetPayloadBodyByHash request %d", reqIndex)
  startTime := time.Now()
  defer func() {
    info "Ended GetPayloadBodyByHash request %d, %s", reqIndex, time.Since(startTime))
  }()
  payloads := make([]ExecutableData, 0)
  hashes := make([]common.Hash, 0)
  if len(req.BlockNumbers) > 0 {
    for _, n := range req.BlockNumbers {
      if p, ok := payloadHistory[n]; ok {
        payloads = append(payloads, p)
        hashes = append(hashes, p.BlockHash)
      } else {
        # signal to request an unknown hash (random)
        randHash := common.Hash{}
        randomBytes(randHash[:])
        payloads = append(payloads, nil)
        hashes = append(hashes, randHash)
      }
    }
  }
  if req.Start > 0 && req.End > 0 {
    for n := req.Start; n <= req.End; n++ {
      if p, ok := payloadHistory[n]; ok {
        payloads = append(payloads, p)
        hashes = append(hashes, p.BlockHash)
      } else {
        # signal to request an unknown hash (random)
        randHash := common.Hash{}
        randomBytes(randHash[:])
        payloads = append(payloads, nil)
        hashes = append(hashes, randHash)
      }
    }
  }
  if len(payloads) == 0 {
    panic("invalid test")
  }

  r := testEngine.TestEngineGetPayloadBodiesByHashV1(hashes)
  r.expectPayloadBodiesCount(uint64(len(payloads)))
  for i, p := range payloads {
    var expectedPayloadBody ExecutionPayloadBodyV1
    if p != nil {
      expectedPayloadBody = ExecutionPayloadBodyV1{
        Transactions: p.Transactions,
        Withdrawals:  p.Withdrawals,
      }
    }
    r.expectPayloadBody(uint64(i), expectedPayloadBody)
  }

}
]#

proc execute*(ws: GetPayloadBodiesSpec, t: TestEnv): bool =
  WDBaseSpec(ws).skipBaseVerifications = true
  testCond WDBaseSpec(ws).execute(t)

#[
  payloadHistory := t.clMock.ExecutedPayloadHistory

  testEngine := t.TestEngine

  if ws.GenerateSidechain {

    # First generate an extra payload on top of the canonical chain
    # Generate more withdrawals
    nextWithdrawals, _ := ws.GenerateWithdrawalsForBlock(payloadHistory.latestWithdrawalsIndex(), ws.getWithdrawalsStartAccount())

    f := t.rpcClient.forkchoiceUpdatedV2(
      &beacon.ForkchoiceStateV1{
        HeadBlockHash: t.clMock.latestHeader.Hash(),
      },
      PayloadAttributes{
        Timestamp:   t.clMock.latestHeader.Time + ws.getBlockTimeIncrements(),
        Withdrawals: nextWithdrawals,
      },
    )
    f.expectPayloadStatus(PayloadExecutionStatus.valid)

    # Wait for payload to be built
    await sleepAsync(time.Second)

    # Get the next canonical payload
    p := t.rpcClient.getPayloadV2(f.Response.PayloadID)
    p.expectNoError()
    nextCanonicalPayload := &p.Payload

    # Now we have an extra payload that follows the canonical chain,
    # but we need a side chain for the test.
    customizer := CustomPayloadData(
      Withdrawals: RandomizeWithdrawalsOrder(t.clMock.latestExecutedPayload.Withdrawals),
    }
    sidechainCurrent, _, err := customizer.CustomizePayload(&t.clMock.latestExecutedPayload, t.clMock.latestPayloadAttributes.BeaconRoot)
    if err != nil {
      error "Error obtaining custom sidechain payload: %v", t.TestName, err)
    }
    customizer = CustomPayloadData(
      ParentHash:  &sidechainCurrent.BlockHash,
      Withdrawals: RandomizeWithdrawalsOrder(nextCanonicalPayload.Withdrawals),
    }
    sidechainHead, _, err := customizer.CustomizePayload(nextCanonicalPayload, t.clMock.latestPayloadAttributes.BeaconRoot)
    if err != nil {
      error "Error obtaining custom sidechain payload: %v", t.TestName, err)
    }

    # Send both sidechain payloads as engine_newPayloadV2
    n1 := t.rpcClient.newPayloadV2(sidechainCurrent)
    n1.expectStatus(PayloadExecutionStatus.valid)
    n2 := t.rpcClient.newPayloadV2(sidechainHead)
    n2.expectStatus(PayloadExecutionStatus.valid)
  } else if ws.AfterSync {
    # Spawn a secondary client which will need to sync to the primary client
    secondaryEngine, err := hive_rpc.HiveRPCEngineStarter{}.StartClient(t.T, t.TestContext, t.Genesis, t.ClientParams, t.ClientFiles, t.Engine)
    if err != nil {
      error "Unable to spawn a secondary client: %v", t.TestName, err)
    }
    secondaryEngineTest := test.NewTestEngineClient(t, secondaryEngine)
    t.clMock.AddEngineClient(secondaryEngine)

  loop:
    for {
      select {
      case <-t.TimeoutContext.Done():
        error "Timeout while waiting for secondary client to sync", t.TestName)
      case <-time.After(time.Second):
        secondaryEngineTest.newPayloadV2(
          &t.clMock.latestExecutedPayload,
        )
        r := secondaryEngineTest.TestEngineForkchoiceUpdatedV2(
          &t.clMock.latestForkchoice,
          nil,
        )
        if r.Response.PayloadStatus.Status == PayloadExecutionStatus.valid {
          break loop
        }
        if r.Response.PayloadStatus.Status == PayloadExecutionStatus.invalid {
          error "Syncing client rejected valid chain: %s", t.TestName, r.Response)
        }
      }
    }

    # GetPayloadBodies will be sent to the secondary client
    testEngine = secondaryEngineTest
  }

  # Now send the range request, which should ignore any sidechain
  if ws.Parallel {
    wg := new(sync.WaitGroup)
    type RequestIndex struct {
      Request GetPayloadBodyRequest
      Index   int
    }
    workChan := make(chan *RequestIndex)
    workers := 16
    wg.Add(workers)
    for w := 0; w < workers; w++ {
      go func() {
        defer wg.Done()
        for req := range workChan {
          req.Request.Verify(req.Index, testEngine, payloadHistory)
        }
      }()
    }
    repeat := 1
    if ws.RequestsRepeat > 0 {
      repeat = ws.RequestsRepeat
    }
    for j := 0; j < repeat; j++ {
      for i, req := range ws.getPayloadBodiesRequests {
        workChan <- &RequestIndex{
          Request: req,
          Index:   i + (j * repeat),
        }
      }
    }

    close(workChan)
    wg.Wait()
  } else {
    for i, req := range ws.getPayloadBodiesRequests {
      req.Verify(i, testEngine, payloadHistory)
]#
