import
  stint,
  chronos,
  chronicles,
  ./wd_base_spec,
  ../test_env,
  ../engine_client,
  ../types

# Withdrawals re-org spec:
# Specifies a withdrawals test where the withdrawals re-org can happen
# even to a point before withdrawals were enabled, or simply to a previous
# withdrawals block.
type
  ReorgSpec* = ref object of WDBaseSpec
    reOrgBlockCount*        : uint64 # How many blocks the re-org will replace, including the head
    reOrgViaSync*           : bool   # Whether the client should fetch the sidechain by syncing from the secondary client
    sidechainTimeIncrements*: uint64
    slotsToSafe*            : UInt256
    slotsToFinalized*       : UInt256
    timeoutSeconds*         : int
    
#[
func (ws *WithdrawalsReorgSpec) GetSidechainSplitHeight() uint64 {
  if ws.ReOrgBlockCount > ws.getTotalPayloadCount() {
    panic("invalid payload/re-org configuration")

  return ws.getTotalPayloadCount() + 1 - ws.ReOrgBlockCount

func (ws *WithdrawalsReorgSpec) GetSidechainBlockTimeIncrements() uint64 {
  if ws.SidechainTimeIncrements == 0 {
    return ws.getBlockTimeIncrements()

  return ws.SidechainTimeIncrements

func (ws *WithdrawalsReorgSpec) GetSidechainWithdrawalsForkHeight() uint64 {
  if ws.getSidechainBlockTimeIncrements() != ws.getBlockTimeIncrements() {
    # Block timestamp increments in both chains are different so need to calculate different heights, only if split happens before fork
    if ws.getSidechainSplitHeight() == 0 {
      # We cannot split by having two different genesis blocks.
      panic("invalid sidechain split height")

    if ws.getSidechainSplitHeight() <= ws.WithdrawalsForkHeight {
      # We need to calculate the height of the fork on the sidechain
      sidechainSplitBlockTimestamp := ((ws.getSidechainSplitHeight() - 1) * ws.getBlockTimeIncrements())
      remainingTime := (ws.getWithdrawalsGenesisTimeDelta() - sidechainSplitBlockTimestamp)
      if remainingTime == 0 {
        return ws.getSidechainSplitHeight()

      return ((remainingTime - 1) / ws.SidechainTimeIncrements) + ws.getSidechainSplitHeight()

  return ws.WithdrawalsForkHeight
]#

proc execute*(ws: ReorgSpec, t: TestEnv): bool =
  testCond waitFor t.clMock.waitForTTD()

  return true
#[
  # Spawn a secondary client which will produce the sidechain
  secondaryEngine, err := hive_rpc.HiveRPCEngineStarter{}.StartClient(t.T, t.TestContext, t.Genesis, t.ClientParams, t.ClientFiles, t.Engine)
  if err != nil {
    error "Unable to spawn a secondary client: %v", t.TestName, err)
  }
  secondaryEngineTest := test.NewTestEngineClient(t, secondaryEngine)
  # t.clMock.AddEngineClient(secondaryEngine)

  var (
    canonicalStartAccount       = big.NewInt(0x1000)
    canonicalNextIndex          = uint64(0)
    sidechainStartAccount       = new(big.Int).SetBit(common.Big0, 160, 1)
    sidechainNextIndex          = uint64(0)
    sidechainwdHistory = make(wdHistory)
    sidechain                   = make(map[uint64]*typ.ExecutableData)
    sidechainPayloadId          *beacon.PayloadID
  )

  # Sidechain withdraws on the max account value range 0xffffffffffffffffffffffffffffffffffffffff
  sidechainStartAccount.Sub(sidechainStartAccount, big.NewInt(int64(ws.getWithdrawableAccountCount())+1))

  t.clMock.ProduceBlocks(int(ws.getPreWithdrawalsBlockCount()+ws.WithdrawalsBlockCount), clmock.BlockProcessCallbacks{
    OnPayloadProducerSelected: proc(): bool =
      t.clMock.NextWithdrawals = nil

      if t.clMock.CurrentPayloadNumber >= ws.WithdrawalsForkHeight {
        # Prepare some withdrawals
        t.clMock.NextWithdrawals, canonicalNextIndex = ws.GenerateWithdrawalsForBlock(canonicalNextIndex, canonicalStartAccount)
        ws.wdHistory[t.clMock.CurrentPayloadNumber] = t.clMock.NextWithdrawals
      }

      if t.clMock.CurrentPayloadNumber >= ws.getSidechainSplitHeight() {
        # We have split
        if t.clMock.CurrentPayloadNumber >= ws.getSidechainWithdrawalsForkHeight() {
          # And we are past the withdrawals fork on the sidechain
          sidechainwdHistory[t.clMock.CurrentPayloadNumber], sidechainNextIndex = ws.GenerateWithdrawalsForBlock(sidechainNextIndex, sidechainStartAccount)
        } # else nothing to do
      } else {
        # We have not split
        sidechainwdHistory[t.clMock.CurrentPayloadNumber] = t.clMock.NextWithdrawals
        sidechainNextIndex = canonicalNextIndex
      }

    },
    OnRequestNextPayload: proc(): bool =
      # Send transactions to be included in the payload
      txs, err := helper.SendNextTransactions(
        t.TestContext,
        t.clMock.NextBlockProducer,
        &helper.BaseTransactionCreator{
          Recipient: &globals.PrevRandaoContractAddr,
          Amount:    common.Big1,
          Payload:   nil,
          TxType:    t.TestTransactionType,
          GasLimit:  75000,
        },
        ws.getTransactionCountPerPayload(),
      )
      if err != nil {
        error "Error trying to send transactions: %v", t.TestName, err)
      }

      # Error will be ignored here since the tx could have been already relayed
      secondaryEngine.SendTransactions(t.TestContext, txs...)

      if t.clMock.CurrentPayloadNumber >= ws.getSidechainSplitHeight() {
        # Also request a payload from the sidechain
        fcU := beacon.ForkchoiceStateV1{
          HeadBlockHash: t.clMock.latestForkchoice.HeadBlockHash,
        }

        if t.clMock.CurrentPayloadNumber > ws.getSidechainSplitHeight() {
          if lastSidePayload, ok := sidechain[t.clMock.CurrentPayloadNumber-1]; !ok {
            panic("sidechain payload not found")
          } else {
            fcU.HeadBlockHash = lastSidePayload.BlockHash
          }
        }

        var version int
        pAttributes := typ.PayloadAttributes{
          Random:                t.clMock.latestPayloadAttributes.Random,
          SuggestedFeeRecipient: t.clMock.latestPayloadAttributes.SuggestedFeeRecipient,
        }
        if t.clMock.CurrentPayloadNumber > ws.getSidechainSplitHeight() {
          pAttributes.Timestamp = sidechain[t.clMock.CurrentPayloadNumber-1].Timestamp + uint64(ws.getSidechainBlockTimeIncrements())
        } else if t.clMock.CurrentPayloadNumber == ws.getSidechainSplitHeight() {
          pAttributes.Timestamp = t.clMock.latestHeader.Time + uint64(ws.getSidechainBlockTimeIncrements())
        } else {
          pAttributes.Timestamp = t.clMock.latestPayloadAttributes.Timestamp
        }
        if t.clMock.CurrentPayloadNumber >= ws.getSidechainWithdrawalsForkHeight() {
          # Withdrawals
          version = 2
          pAttributes.Withdrawals = sidechainwdHistory[t.clMock.CurrentPayloadNumber]
        } else {
          # No withdrawals
          version = 1
        }

        info "Requesting sidechain payload %d: %v", t.TestName, t.clMock.CurrentPayloadNumber, pAttributes)

        r := secondaryEngineTest.forkchoiceUpdated(&fcU, &pAttributes, version)
        r.expectNoError()
        r.expectPayloadStatus(test.Valid)
        if r.Response.PayloadID == nil {
          error "Unable to get a payload ID on the sidechain", t.TestName)
        }
        sidechainPayloadId = r.Response.PayloadID
      }
    },
    OnGetPayload: proc(): bool =
      var (
        version int
        payload *typ.ExecutableData
      )
      if t.clMock.CurrentPayloadNumber >= ws.getSidechainWithdrawalsForkHeight() {
        version = 2
      } else {
        version = 1
      }
      if t.clMock.latestPayloadBuilt.Number >= ws.getSidechainSplitHeight() {
        # This payload is built by the secondary client, hence need to manually fetch it here
        r := secondaryEngineTest.getPayload(sidechainPayloadId, version)
        r.expectNoError()
        payload = &r.Payload
        sidechain[payload.Number] = payload
      } else {
        # This block is part of both chains, simply forward it to the secondary client
        payload = &t.clMock.latestPayloadBuilt
      }
      r := secondaryEngineTest.newPayload(payload, nil, nil, version)
      r.expectStatus(test.Valid)
      p := secondaryEngineTest.forkchoiceUpdated(
        &beacon.ForkchoiceStateV1{
          HeadBlockHash: payload.BlockHash,
        },
        nil,
        version,
      )
      p.expectPayloadStatus(test.Valid)
    },
  })

  sidechainHeight := t.clMock.latestExecutedPayload.Number

  if ws.WithdrawalsForkHeight < ws.getSidechainWithdrawalsForkHeight() {
    # This means the canonical chain forked before the sidechain.
    # Therefore we need to produce more sidechain payloads to reach
    # at least`ws.WithdrawalsBlockCount` withdrawals payloads produced on
    # the sidechain.
    for i := uint64(0); i < ws.getSidechainWithdrawalsForkHeight()-ws.WithdrawalsForkHeight; i++ {
      sidechainwdHistory[sidechainHeight+1], sidechainNextIndex = ws.GenerateWithdrawalsForBlock(sidechainNextIndex, sidechainStartAccount)
      pAttributes := typ.PayloadAttributes{
        Timestamp:             sidechain[sidechainHeight].Timestamp + ws.getSidechainBlockTimeIncrements(),
        Random:                t.clMock.latestPayloadAttributes.Random,
        SuggestedFeeRecipient: t.clMock.latestPayloadAttributes.SuggestedFeeRecipient,
        Withdrawals:           sidechainwdHistory[sidechainHeight+1],
      }
      r := secondaryEngineTest.forkchoiceUpdatedV2(&beacon.ForkchoiceStateV1{
        HeadBlockHash: sidechain[sidechainHeight].BlockHash,
      }, &pAttributes)
      r.expectPayloadStatus(test.Valid)
      time.Sleep(time.Second)
      p := secondaryEngineTest.getPayloadV2(r.Response.PayloadID)
      p.expectNoError()
      s := secondaryEngineTest.newPayloadV2(&p.Payload)
      s.expectStatus(test.Valid)
      q := secondaryEngineTest.forkchoiceUpdatedV2(
        &beacon.ForkchoiceStateV1{
          HeadBlockHash: p.Payload.BlockHash,
        },
        nil,
      )
      q.expectPayloadStatus(test.Valid)
      sidechainHeight++
      sidechain[sidechainHeight] = &p.Payload
    }
  }

  # Check the withdrawals on the latest
  ws.wdHistory.VerifyWithdrawals(
    sidechainHeight,
    nil,
    t.TestEngine,
  )

  if ws.ReOrgViaSync {
    # Send latest sidechain payload as NewPayload + FCU and wait for sync
  loop:
    for {
      r := t.rpcClient.newPayloadV2(sidechain[sidechainHeight])
      r.expectNoError()
      p := t.rpcClient.forkchoiceUpdatedV2(
        &beacon.ForkchoiceStateV1{
          HeadBlockHash: sidechain[sidechainHeight].BlockHash,
        },
        nil,
      )
      p.expectNoError()
      if p.Response.PayloadStatus.Status == test.Invalid {
        error "Primary client invalidated side chain", t.TestName)
      }
      select {
      case <-t.TimeoutContext.Done():
        error "Timeout waiting for sync", t.TestName)
      case <-time.After(time.Second):
        b := t.rpcClient.BlockByNumber(nil)
        if b.Block.Hash() == sidechain[sidechainHeight].BlockHash {
          # sync successful
          break loop
        }
      }
    }
  } else {
    # Send all payloads one by one to the primary client
    for payloadNumber := ws.getSidechainSplitHeight(); payloadNumber <= sidechainHeight; payloadNumber++ {
      payload, ok := sidechain[payloadNumber]
      if !ok {
        error "Invalid payload %d requested.", t.TestName, payloadNumber)
      }
      var version int
      if payloadNumber >= ws.getSidechainWithdrawalsForkHeight() {
        version = 2
      } else {
        version = 1
      }
      info "Sending sidechain payload %d, hash=%s, parent=%s", t.TestName, payloadNumber, payload.BlockHash, payload.ParentHash)
      r := t.rpcClient.newPayload(payload, nil, nil, version)
      r.expectStatusEither(test.Valid, test.Accepted)
      p := t.rpcClient.forkchoiceUpdated(
        &beacon.ForkchoiceStateV1{
          HeadBlockHash: payload.BlockHash,
        },
        nil,
        version,
      )
      p.expectPayloadStatus(test.Valid)
    }
  }

  # Verify withdrawals changed
  sidechainwdHistory.VerifyWithdrawals(
    sidechainHeight,
    nil,
    t.TestEngine,
  )
  # Verify all balances of accounts in the original chain didn't increase
  # after the fork.
  # We are using different accounts credited between the canonical chain
  # and the fork.
  # We check on `latest`.
  ws.wdHistory.VerifyWithdrawals(
    ws.WithdrawalsForkHeight-1,
    nil,
    t.TestEngine,
  )

  # Re-Org back to the canonical chain
  r := t.rpcClient.forkchoiceUpdatedV2(&beacon.ForkchoiceStateV1{
    HeadBlockHash: t.clMock.latestPayloadBuilt.BlockHash,
  }, nil)
  r.expectPayloadStatus(test.Valid)
]#
