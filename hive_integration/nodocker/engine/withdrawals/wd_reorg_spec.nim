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
  std/tables,
  stint,
  chronos,
  chronicles,
  eth/common,
  ./wd_base_spec,
  ./wd_history,
  ../test_env,
  ../engine_client,
  ../types,
  ../base_spec,
  ../../../../nimbus/beacon/web3_eth_conv,
  ../../../../nimbus/utils/utils

# Withdrawals re-org spec:
# Specifies a withdrawals test where the withdrawals re-org can happen
# even to a point before withdrawals were enabled, or simply to a previous
# withdrawals block.
type
  ReorgSpec* = ref object of WDBaseSpec
    # How many blocks the re-org will replace, including the head
    reOrgBlockCount*        : int
    # Whether the client should fetch the sidechain by syncing from the secondary client
    reOrgViaSync*           : bool
    sidechainTimeIncrements*: int

  Sidechain = ref object
    startAccount: UInt256
    nextIndex   : int
    wdHistory   : WDHistory
    sidechain   : Table[uint64, ExecutionPayload]
    payloadId   : PayloadID
    height      : uint64
    attr        : Opt[PayloadAttributes]

  Canonical = ref object
    startAccount: UInt256
    nextIndex   : int

proc getSidechainSplitHeight(ws: ReorgSpec): int =
  doAssert(ws.reOrgBlockCount <= ws.getTotalPayloadCount())
  return ws.getTotalPayloadCount() + 1 - ws.reOrgBlockCount

proc getSidechainBlockTimeIncrements(ws: ReorgSpec): int=
  if ws.sidechainTimeIncrements == 0:
    return ws.getBlockTimeIncrements()
  ws.sidechainTimeIncrements

proc getSidechainforkHeight(ws: ReorgSpec): int =
  if ws.getSidechainBlockTimeIncrements() != ws.getBlockTimeIncrements():
    # Block timestamp increments in both chains are different so need to
    # calculate different heights, only if split happens before fork.
    # We cannot split by having two different genesis blocks.
    doAssert(ws.getSidechainSplitHeight() != 0, "invalid sidechain split height")

    if ws.getSidechainSplitHeight() <= ws.forkHeight:
      # We need to calculate the height of the fork on the sidechain
      let sidechainSplitBlocktimestamp = (ws.getSidechainSplitHeight() - 1) * ws.getBlockTimeIncrements()
      let remainingTime = ws.getWithdrawalsGenesisTimeDelta() - sidechainSplitBlocktimestamp
      if remainingTime == 0 :
        return ws.getSidechainSplitHeight()

      return ((remainingTime - 1) div ws.sidechainTimeIncrements) + ws.getSidechainSplitHeight()

  return ws.forkHeight

proc execute*(ws: ReorgSpec, env: TestEnv): bool =
  result = true

  testCond waitFor env.clMock.waitForTTD()

  # Spawn a secondary client which will produce the sidechain
  let sec = env.addEngine(addToCL = false)

  var
    canonical = Canonical(
      startAccount: u256(0x1000),
      nextIndex   : 0,
    )
    sidechain = Sidechain(
      startAccount: 1.u256 shl 160,
      nextIndex   : 0,
      wdHistory   : WDHistory(),
      sidechain   : Table[uint64, ExecutionPayload]()
    )

  # Sidechain withdraws on the max account value range 0xffffffffffffffffffffffffffffffffffffffff
  sidechain.startAccount -= u256(ws.getWithdrawableAccountCount()+1)

  let numBlocks = ws.getPreWithdrawalsBlockCount()+ws.wdBlockCount
  let pbRes = env.clMock.produceBlocks(numBlocks, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      env.clMock.nextWithdrawals = Opt.none(seq[WithdrawalV1])

      if env.clMock.currentPayloadNumber >= ws.forkHeight.uint64:
        # Prepare some withdrawals
        let wfb = ws.generateWithdrawalsForBlock(canonical.nextIndex, canonical.startAccount)
        env.clMock.nextWithdrawals = Opt.some(w3Withdrawals wfb.wds)
        canonical.nextIndex = wfb.nextIndex
        ws.wdHistory.put(env.clMock.currentPayloadNumber, wfb.wds)

      if env.clMock.currentPayloadNumber >= ws.getSidechainSplitHeight().uint64:
        # We have split
        if env.clMock.currentPayloadNumber >= ws.getSidechainforkHeight().uint64:
          # And we are past the withdrawals fork on the sidechain
          let wfb = ws.generateWithdrawalsForBlock(sidechain.nextIndex, sidechain.startAccount)
          sidechain.wdHistory.put(env.clMock.currentPayloadNumber, wfb.wds)
          sidechain.nextIndex = wfb.nextIndex
      else:
        if env.clMock.nextWithdrawals.isSome:
          let wds = ethWithdrawals env.clMock.nextWithdrawals.get()
          sidechain.wdHistory.put(env.clMock.currentPayloadNumber, wds)
        sidechain.nextIndex = canonical.nextIndex

      return true
    ,
    onRequestNextPayload: proc(): bool =
      # Send transactions to be included in the payload
      let txs = env.makeTxs(
        BaseTx(
          recipient: Opt.some(prevRandaoContractAddr),
          amount:    1.u256,
          txType:    ws.txType,
          gasLimit:  75000.GasInt,
        ),
        ws.getTransactionCountPerPayload()
      )

      testCond env.sendTxs(env.clMock.nextBlockProducer, txs):
        error "Error trying to send transaction"

      # Error will be ignored here since the tx could have been already relayed
      discard env.sendTxs(sec, txs)

      if env.clMock.currentPayloadNumber >= ws.getSidechainSplitHeight().uint64:
        # Also request a payload from the sidechain
        var fcState = ForkchoiceStateV1(
          headBlockHash: env.clMock.latestForkchoice.headBlockHash,
        )

        if env.clMock.currentPayloadNumber > ws.getSidechainSplitHeight().uint64:
          let lastSidePayload = sidechain.sidechain[env.clMock.currentPayloadNumber-1]
          fcState.headBlockHash = lastSidePayload.blockHash

        var attr = PayloadAttributes(
          prevRandao:            env.clMock.latestPayloadAttributes.prevRandao,
          suggestedFeeRecipient: env.clMock.latestPayloadAttributes.suggestedFeeRecipient,
        )

        if env.clMock.currentPayloadNumber > ws.getSidechainSplitHeight().uint64:
          attr.timestamp = w3Qty(sidechain.sidechain[env.clMock.currentPayloadNumber-1].timestamp, ws.getSidechainBlockTimeIncrements())
        elif env.clMock.currentPayloadNumber == ws.getSidechainSplitHeight().uint64:
          attr.timestamp = w3Qty(env.clMock.latestHeader.timestamp, ws.getSidechainBlockTimeIncrements())
        else:
          attr.timestamp = env.clMock.latestPayloadAttributes.timestamp

        if env.clMock.currentPayloadNumber >= ws.getSidechainforkHeight().uint64:
          # Withdrawals
          let rr = sidechain.wdHistory.get(env.clMock.currentPayloadNumber)
          testCond rr.isOk:
            error "sidechain wd", msg=rr.error

          attr.withdrawals = Opt.some(w3Withdrawals rr.get)

        info "Requesting sidechain payload",
          number=env.clMock.currentPayloadNumber

        sidechain.attr = Opt.some(attr)
        let r = sec.client.forkchoiceUpdated(fcState, attr)
        r.expectNoError()
        r.expectPayloadStatus(PayloadExecutionStatus.valid)
        testCond r.get().payloadID.isSome:
          error "Unable to get a payload ID on the sidechain"
        sidechain.payloadId = r.get().payloadID.get()

      return true
    ,
    onGetPayload: proc(): bool =
      var
        payload: ExecutionPayload

      if env.clMock.latestPayloadBuilt.blockNumber.uint64 >= ws.getSidechainSplitHeight().uint64:
        # This payload is built by the secondary client, hence need to manually fetch it here
        doAssert(sidechain.attr.isSome)
        let version = sidechain.attr.get().version
        let r = sec.client.getPayload(sidechain.payloadId, version)
        r.expectNoError()
        payload = r.get().executionPayload
        sidechain.sidechain[payload.blockNumber.uint64] = payload
      else:
        # This block is part of both chains, simply forward it to the secondary client
        payload = env.clMock.latestPayloadBuilt

      let r = sec.client.newPayload(payload)
      r.expectStatus(PayloadExecutionStatus.valid)

      let fcState = ForkchoiceStateV1(
        headBlockHash: payload.blockHash,
      )
      let p = sec.client.forkchoiceUpdated(payload.version, fcState)
      p.expectPayloadStatus(PayloadExecutionStatus.valid)
      return true
  ))
  testCond pbRes

  sidechain.height = env.clMock.latestExecutedPayload.blockNumber.uint64

  if ws.forkHeight < ws.getSidechainforkHeight():
    # This means the canonical chain forked before the sidechain.
    # Therefore we need to produce more sidechain payloads to reach
    # at least`ws.WithdrawalsBlockCount` withdrawals payloads produced on
    # the sidechain.
    let height = ws.getSidechainforkHeight()-ws.forkHeight
    for i in 0..<height:
      let
        wfb = ws.generateWithdrawalsForBlock(sidechain.nextIndex, sidechain.startAccount)

      sidechain.wdHistory.put(sidechain.height+1, wfb.wds)
      sidechain.nextIndex = wfb.nextIndex

      let wds = sidechain.wdHistory.get(sidechain.height+1).valueOr:
        echo "get wd history error ", error
        return false

      let
        attr = PayloadAttributes(
          timestamp:             w3Qty(sidechain.sidechain[sidechain.height].timestamp, ws.getSidechainBlockTimeIncrements()),
          prevRandao:            env.clMock.latestPayloadAttributes.prevRandao,
          suggestedFeeRecipient: env.clMock.latestPayloadAttributes.suggestedFeeRecipient,
          withdrawals:           Opt.some(w3Withdrawals wds),
        )
        fcState = ForkchoiceStateV1(
          headBlockHash: sidechain.sidechain[sidechain.height].blockHash,
        )

      let r = sec.client.forkchoiceUpdatedV2(fcState, Opt.some(attr))
      r.expectPayloadStatus(PayloadExecutionStatus.valid)

      let p = sec.client.getPayloadV2(r.get().payloadID.get)
      p.expectNoError()

      let z = p.get()
      let s = sec.client.newPayloadV2(z.executionPayload)
      s.expectStatus(PayloadExecutionStatus.valid)

      let fs = ForkchoiceStateV1(headBlockHash: z.executionPayload.blockHash)

      let q = sec.client.forkchoiceUpdatedV2(fs)
      q.expectPayloadStatus(PayloadExecutionStatus.valid)

      inc sidechain.height
      sidechain.sidechain[sidechain.height] = executionPayload(z.executionPayload)

  # Check the withdrawals on the latest
  let res = ws.wdHistory.verifyWithdrawals(sidechain.height, Opt.none(uint64), env.client)
  testCond res.isOk

  if ws.reOrgViaSync:
    # Send latest sidechain payload as NewPayload + FCU and wait for sync
    let
      payload = sidechain.sidechain[sidechain.height]
      sideHash = sidechain.sidechain[sidechain.height].blockHash
      sleep = DefaultSleep
      period = chronos.seconds(sleep)

    var loop = 0
    if ws.timeoutSeconds == 0:
      ws.timeoutSeconds = DefaultTimeout

    while loop < ws.timeoutSeconds:
      let r = env.client.newPayloadV2(payload.V2)
      r.expectNoError()
      let fcState = ForkchoiceStateV1(headBlockHash: sideHash)
      let p = env.client.forkchoiceUpdatedV2(fcState)
      p.expectNoError()

      let status = p.get().payloadStatus.status
      if status == PayloadExecutionStatus.invalid:
        error "Primary client invalidated side chain"
        return false

      let b = env.client.latestHeader()
      testCond b.isOk
      let header = b.get
      if header.blockHash == sideHash:
        # sync successful
        break

      waitFor sleepAsync(period)
      loop += sleep
  else:
    # Send all payloads one by one to the primary client
    var payloadNumber = ws.getSidechainSplitHeight()
    while payloadNumber.uint64 <= sidechain.height:
      let payload = sidechain.sidechain[payloadNumber.uint64]
      var version = Version.V1
      if payloadNumber >= ws.getSidechainforkHeight():
        version = Version.V2

      info "Sending sidechain",
        payloadNumber,
        hash=payload.blockHash.short,
        parentHash=payload.parentHash.short

      let r = env.client.newPayload(payload)
      r.expectStatusEither([PayloadExecutionStatus.valid, PayloadExecutionStatus.accepted])

      let fcState = ForkchoiceStateV1(headBlockHash: payload.blockHash)
      let p = env.client.forkchoiceUpdated(version, fcState)
      p.expectPayloadStatus(PayloadExecutionStatus.valid)
      inc payloadNumber


  # Verify withdrawals changed
  let r2 = sidechain.wdHistory.verifyWithdrawals(sidechain.height, Opt.none(uint64), env.client)
  testCond r2.isOk

  # Verify all balances of accounts in the original chain didn't increase
  # after the fork.
  # We are using different accounts credited between the canonical chain
  # and the fork.
  # We check on `latest`.
  let r3 = ws.wdHistory.verifyWithdrawals(uint64(ws.forkHeight-1), Opt.none(uint64), env.client)
  testCond r3.isOk

  # Re-Org back to the canonical chain
  let fcState = ForkchoiceStateV1(headBlockHash: env.clMock.latestPayloadBuilt.blockHash)
  let r = env.client.forkchoiceUpdatedV2(fcState)
  r.expectPayloadStatus(PayloadExecutionStatus.valid)
