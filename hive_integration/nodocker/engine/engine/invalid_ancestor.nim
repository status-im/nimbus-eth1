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
  std/strutils,
  chronicles,
  eth/common,
  eth/common/eth_types_rlp,
  ./engine_spec,
  ../cancun/customizer,
  ../../../../nimbus/utils/utils,
  ../../../../nimbus/beacon/payload_conv

# Attempt to re-org to a chain which at some point contains an unknown payload which is also invalid.
# Then reveal the invalid payload and expect that the client rejects it and rejects forkchoice updated calls to this chain.
# The invalidIndex parameter determines how many payloads apart is the common ancestor from the block that invalidates the chain,
# with a value of 1 meaning that the immediate payload after the common ancestor will be invalid.

type
  InvalidMissingAncestorReOrgTest* = ref object of EngineSpec
    sidechainLength*: int
    invalidIndex*: int
    invalidField*: InvalidPayloadBlockField
    emptyTransactions*: bool

  Shadow = ref object
    payloads: seq[ExecutableData]
    n: int
    cAHeight: int

method withMainFork(cs: InvalidMissingAncestorReOrgTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: InvalidMissingAncestorReOrgTest): string =
  "Invalid Missing Ancestor ReOrg, $1, EmptyTxs=$2, Invalid P$3" %
    [$cs.invalidField, $cs.emptyTransactions, $cs.invalidIndex]

method execute(cs: InvalidMissingAncestorReOrgTest, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  # Save the common ancestor
  let cA = env.clMock.latestExecutableData

  # Slice to save the side B chain
  var shadow = Shadow()

  # Append the common ancestor
  shadow.payloads.add(cA)

  # Produce blocks but at the same time create an side chain which contains an invalid payload at some point (INV_P)
  # CommonAncestor◄─▲── P1 ◄─ P2 ◄─ P3 ◄─ ... ◄─ Pn
  #                 │
  #                 └── P1' ◄─ P2' ◄─ ... ◄─ INV_P ◄─ ... ◄─ Pn'
  var pbRes = env.clMock.produceBlocks(
    cs.sidechainLength,
    BlockProcessCallbacks(
      onPayloadProducerSelected: proc(): bool =
        # Function to send at least one transaction each block produced.
        # Empty Txs Payload with invalid stateRoot discovered an issue in geth sync, hence this is customizable.
        if not cs.emptyTransactions:
          # Send the transaction to the globals.PrevRandaoContractAddr
          let eng = env.clMock.nextBlockProducer
          let ok = env.sendNextTx(
            eng,
            BaseTx(
              recipient: Opt.some(prevRandaoContractAddr),
              amount: 1.u256,
              txType: cs.txType,
              gasLimit: 75000,
            ),
          )

          testCond ok:
            fatal "Error trying to send transaction"
        return true,
      onGetPayload: proc(): bool =
        # Insert extraData to ensure we deviate from the main payload, which contains empty extradata
        let customizer = CustomPayloadData(
          parentHash: Opt.some(ethHash shadow.payloads[^1].blockHash),
          extraData: Opt.some(@[0x01.byte]),
        )

        var sidePayload = customizer.customizePayload(env.clMock.latestExecutableData)
        if shadow.payloads.len == cs.invalidIndex:
          sidePayload = env.generateInvalidPayload(sidePayload, cs.invalidField)
        shadow.payloads.add sidePayload
        return true,
    ),
  )
  testCond pbRes

  pbRes = env.clMock.produceSingleBlock(
    BlockProcessCallbacks(
      # Note: We perform the test in the middle of payload creation by the CL Mock, in order to be able to
      # re-org back into this chain and use the new payload without issues.
      onGetPayload: proc(): bool =
        # Now let's send the side chain to the client using newPayload/sync
        for i in 1 .. cs.sidechainLength:
          # Send the payload
          var payloadValidStr = "VALID"
          if i == cs.invalidIndex:
            payloadValidStr = "INVALID"
          elif i > cs.invalidIndex:
            payloadValidStr = "VALID with INVALID ancestor"

          info "Invalid chain payload",
            index = i,
            payloadValidStr,
            blockHash = shadow.payloads[i].blockHash.short,
            number = shadow.payloads[i].blockNumber.uint64

          let version = env.engine.version(shadow.payloads[i].timestamp)
          let r = env.engine.client.newPayload(version, shadow.payloads[i])
          let fcState = ForkchoiceStateV1(headblockHash: shadow.payloads[i].blockHash)
          let p = env.engine.client.forkchoiceUpdated(version, fcState)

          if i == cs.invalidIndex:
            # If this is the first payload after the common ancestor, and this is the payload we invalidated,
            # then we have all the information to determine that this payload is invalid.
            r.expectStatus(PayloadExecutionStatus.invalid)
            r.expectLatestValidHash(shadow.payloads[i - 1].blockHash)
          elif i > cs.invalidIndex:
            # We have already sent the invalid payload, but the client could've discarded it.
            # In reality the CL will not get to this point because it will have already received the `INVALID`
            # response from the previous payload.
            # The node might save the parent as invalid, thus returning INVALID
            r.expectStatusEither(
              [
                PayloadExecutionStatus.accepted, PayloadExecutionStatus.syncing,
                PayloadExecutionStatus.invalid,
              ]
            )
            let status = r.get.status
            if status in
                [PayloadExecutionStatus.accepted, PayloadExecutionStatus.syncing]:
              r.expectLatestValidHash()
            elif status == PayloadExecutionStatus.invalid:
              r.expectLatestValidHash(shadow.payloads[cs.invalidIndex - 1].blockHash)
          else:
            # This is one of the payloads before the invalid one, therefore is valid.
            r.expectStatus(PayloadExecutionStatus.valid)
            p.expectPayloadStatus(PayloadExecutionStatus.valid)
            p.expectLatestValidHash(shadow.payloads[i].blockHash)

        # Resend the latest correct fcU
        let version = env.engine.version(env.clMock.latestPayloadBuilt.timestamp)
        let r =
          env.engine.client.forkchoiceUpdated(version, env.clMock.latestForkchoice)
        r.expectNoError()
        # After this point, the CL Mock will send the next payload of the canonical chain
        return true
    )
  )

  testCond pbRes
  return true

# Attempt to re-org to a chain which at some point contains an unknown payload which is also invalid.
# Then reveal the invalid payload and expect that the client rejects it and rejects forkchoice updated calls to this chain.
type InvalidMissingAncestorReOrgSyncTest* = ref object of EngineSpec
  # Index of the payload to invalidate, starting with 0 being the common ancestor.
  # Value must be greater than 0.
  invalidIndex*: int
  # Field of the payload to invalidate (see helper module)
  invalidField*: InvalidPayloadBlockField
  # Whether to create payloads with empty transactions or not:
  # Used to test scenarios where the stateRoot is invalidated but its invalidation
  # goes unnoticed by the client because of the lack of transactions.
  emptyTransactions*: bool
  # Height of the common ancestor in the proof-of-stake chain.
  # Value of 0 means the common ancestor is the terminal proof-of-work block.
  commonAncestorHeight*: Option[int]
  # Amount of payloads to produce between the common ancestor and the head of the
  # proof-of-stake chain.
  deviatingPayloadCount*: Option[int]
  # Whether the syncing client must re-org from a canonical chain.
  # If set to true, the client is driven through a valid canonical chain first,
  # and then the client is prompted to re-org to the invalid chain.
  # If set to false, the client is prompted to sync from the genesis
  # or start chain (if specified).
  reOrgFromCanonical*: bool

method withMainFork(
    cs: InvalidMissingAncestorReOrgSyncTest, fork: EngineFork
): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: InvalidMissingAncestorReOrgSyncTest): string =
  "Invalid Missing Ancestor Syncing ReOrg, $1, EmptyTxs=$2, CanonicalReOrg=$3, Invalid P$4" %
    [$cs.invalidField, $cs.emptyTransactions, $cs.reOrgFromCanonical, $cs.invalidIndex]

func blockHeader(ex: ExecutableData): common.BlockHeader =
  blockHeader(ex.basePayload, ex.beaconRoot)

func blockBody(ex: ExecutableData): common.BlockBody =
  blockBody(ex.basePayload)

method execute(cs: InvalidMissingAncestorReOrgSyncTest, env: TestEnv): bool =
  var sec = env.addEngine(true, cs.reOrgFromCanonical)

  # Remove the original client so that it does not receive the payloads created on the canonical chain
  if not cs.reOrgFromCanonical:
    env.clMock.removeEngine(env.engine)

  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  let shadow = Shadow(cAHeight: 5, n: 10)

  # Produce blocks before starting the test
  # Default is to produce 5 PoS blocks before the common ancestor
  if cs.commonAncestorHeight.isSome:
    shadow.cAHeight = cs.commonAncestorHeight.get

  # Save the common ancestor
  doAssert(shadow.cAHeight != 0, "Invalid common ancestor height: " & $shadow.cAHeight)
  testCond env.clMock.produceBlocks(shadow.cAHeight, BlockProcessCallbacks())

  # Amount of blocks to deviate starting from the common ancestor
  # Default is to deviate 10 payloads from the common ancestor
  if cs.deviatingPayloadCount.isSome:
    shadow.n = cs.deviatingPayloadCount.get

  # Slice to save the side B chain
  # Append the common ancestor
  shadow.payloads.add env.clMock.latestExecutableData

  # Produce blocks but at the same time create an side chain which contains an invalid payload at some point (INV_P)
  # CommonAncestor◄─▲── P1 ◄─ P2 ◄─ P3 ◄─ ... ◄─ Pn
  #                 │
  #                 └── P1' ◄─ P2' ◄─ ... ◄─ INV_P ◄─ ... ◄─ Pn'
  info "Starting canonical chain production"
  var pbRes = env.clMock.produceBlocks(
    shadow.n,
    BlockProcessCallbacks(
      onPayloadProducerSelected: proc(): bool =
        # Function to send at least one transaction each block produced.
        # Empty Txs Payload with invalid stateRoot discovered an issue in geth sync, hence this is customizable.
        if not cs.emptyTransactions:
          # Send the transaction to the globals.PrevRandaoContractAddr
          let tc = BaseTx(
            recipient: Opt.some(prevRandaoContractAddr),
            amount: 1.u256,
            txType: cs.txType,
            gasLimit: 75000,
          )
          let ok = env.sendNextTx(env.clMock.nextBlockProducer, tc)
          testCond ok:
            fatal "Error trying to send transaction: "
        return true,
      onGetPayload: proc(): bool =
        var
          # Insert extraData to ensure we deviate from the main payload, which contains empty extradata
          pHash = shadow.payloads[^1].blockHash
          customizer = CustomPayloadData(
            parentHash: Opt.some(ethHash pHash), extraData: Opt.some(@[0x01.byte])
          )
          sidePayload = customizer.customizePayload(env.clMock.latestExecutableData)

        if shadow.payloads.len == cs.invalidIndex:
          sidePayload = env.generateInvalidPayload(sidePayload, cs.invalidField)

        shadow.payloads.add sidePayload
        # TODO: This could be useful to try to produce an invalid block that has some invalid field not included in the ExecutableData
        #let sideBlock = sidePayload.basePayload
        #if shadow.payloads.len == cs.invalidIndex:
        #  var uncle *types.Block
        #  if cs.invalidField == InvalidOmmers:
        #    let number = sideBlock.number.uint64-1
        #    doAssert(env.clMock.executedPayloadHistory.hasKey(number), "FAIL: Unable to get uncle block")
        #    let unclePayload = env.clMock.executedPayloadHistory[number]
        #      # Uncle is a PoS payload
        #      uncle, err = ExecutableDataToBlock(*unclePayload)
        #
        #  # Invalidate fields not available in the ExecutableData
        #  sideBlock, err = generateInvalidPayloadBlock(sideBlock, uncle, cs.invalidField)
        return true,
    ),
  )
  testCond pbRes

  if not cs.reOrgFromCanonical:
    # Add back the original client before side chain production
    env.clMock.addEngine(env.engine)

  info "Starting side chain production"
  pbRes = env.clMock.produceSingleBlock(
    BlockProcessCallbacks(
      # Note: We perform the test in the middle of payload creation by the CL Mock, in order to be able to
      # re-org back into this chain and use the new payload without issues.
      onGetPayload: proc(): bool =
        # Now let's send the side chain to the client using newPayload/sync
        for i in 1 ..< shadow.n:
          # Send the payload
          var payloadValidStr = "VALID"
          if i == cs.invalidIndex:
            payloadValidStr = "INVALID"
          elif i > cs.invalidIndex:
            payloadValidStr = "VALID with INVALID ancestor"

          info "Invalid chain payload", i, msg = payloadValidStr

          if i < cs.invalidIndex:
            let p = shadow.payloads[i]
            let version = sec.version(p.timestamp)
            let r = sec.client.newPayload(version, p)
            #r.ExpectationDescription = "Sent modified payload to secondary client, expected to be accepted"
            r.expectStatusEither(
              [PayloadExecutionStatus.valid, PayloadExecutionStatus.accepted]
            )
            let fcu = ForkchoiceStateV1(headblockHash: p.blockHash)
            let s = sec.client.forkchoiceUpdated(version, fcu)
            #s.ExpectationDescription = "Sent modified payload forkchoice updated to secondary client, expected to be accepted"
            s.expectStatusEither(
              [PayloadExecutionStatus.valid, PayloadExecutionStatus.syncing]
            )
          else:
            let
              invalidHeader = blockHeader(shadow.payloads[i])
              invalidBody = blockBody(shadow.payloads[i])

            testCond sec.setBlock(EthBlock.init(invalidHeader, invalidBody)):
              fatal "TEST ISSUE - Failed to set invalid block"
            info "Invalid block successfully set",
              idx = i, msg = payloadValidStr, hash = invalidHeader.blockHash.short

        # Check that the second node has the correct head
        var res = sec.client.latestHeader()
        testCond res.isOk:
          fatal "TEST ISSUE - Secondary Node unable to reatrieve latest header: ",
            msg = res.error

        let head = res.get()
        testCond head.blockHash == ethHash(shadow.payloads[shadow.n - 1].blockHash):
          fatal "TEST ISSUE - Secondary Node has invalid blockHash",
            got = head.blockHash.short,
            want = shadow.payloads[shadow.n - 1].blockHash.short,
            gotNum = head.number,
            wantNum = shadow.payloads[shadow.n].blockNumber

        info "Secondary Node has correct block"

        if not cs.reOrgFromCanonical:
          # Add the main client as a peer of the secondary client so it is able to sync
          sec.connect(env.engine.node)

          let res = env.engine.client.latestHeader()
          testCond res.isOk:
            fatal "Unable to query main client for latest block", msg = res.error

          let head = res.get
          info "Latest block on main client before sync",
            hash = head.blockHash.short, number = head.number

        # If we are syncing through p2p, we need to keep polling until the client syncs the missing payloads
        let period = chronos.milliseconds(500)
        while true:
          let version = env.engine.version(shadow.payloads[shadow.n].timestamp)
          let r = env.engine.client.newPayload(version, shadow.payloads[shadow.n])
          info "Response from main client", status = r.get.status

          let fcu =
            ForkchoiceStateV1(headblockHash: shadow.payloads[shadow.n].blockHash)
          let s = env.engine.client.forkchoiceUpdated(version, fcu)
          info "Response from main client fcu", status = s.get.payloadStatus.status

          if r.get.status == PayloadExecutionStatus.invalid:
            # We also expect that the client properly returns the LatestValidHash of the block on the
            # side chain that is immediately prior to the invalid payload (or zero if parent is PoW)
            var lvh: Web3Hash
            if shadow.cAHeight != 0 or cs.invalidIndex != 1:
              # Parent is NOT Proof of Work
              lvh = shadow.payloads[cs.invalidIndex - 1].blockHash

            r.expectLatestValidHash(lvh)
            # Response on ForkchoiceUpdated should be the same
            s.expectPayloadStatus(PayloadExecutionStatus.invalid)
            s.expectLatestValidHash(lvh)
            break
          elif r.get.status == PayloadExecutionStatus.valid:
            let res = env.engine.client.latestHeader()
            testCond res.isOk:
              fatal "Unable to get latest block: ", msg = res.error

            # Print last shadow.n blocks, for debugging
            let latestNumber = res.get.number
            var k = latestNumber - uint64(shadow.n)
            if k < 0:
              k = 0

            while k <= latestNumber:
              let res = env.engine.client.headerByNumber(k.uint64)
              testCond res.isOk:
                fatal "Unable to get block", number = k, msg = res.error
              inc k

            fatal "Client returned VALID on an invalid chain", status = r.get.status
            return false

          waitFor sleepAsync(period)

        if not cs.reOrgFromCanonical:
          # We need to send the canonical chain to the main client here
          let start = env.clMock.firstPoSBlockNumber.get
          let stop = env.clMock.latestExecutedPayload.blockNumber.uint64
          for i in start .. stop:
            if env.clMock.executedPayloadHistory.hasKey(i):
              let payload = env.clMock.executedPayloadHistory[i]
              let r = env.engine.client.newPayload(payload)
              r.expectStatus(PayloadExecutionStatus.valid)

        # Resend the latest correct fcU
        let version = env.engine.version(env.clMock.latestPayloadBuilt.timestamp)
        let r =
          env.engine.client.forkchoiceUpdated(version, env.clMock.latestForkchoice)
        r.expectNoError()
        # After this point, the CL Mock will send the next payload of the canonical chain
        return true
    )
  )

  testCond pbRes
  return true
