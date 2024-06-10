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
  ./step_desc,
  ./helpers,
  ./customizer,
  ./blobs,
  ../engine_client,
  ../test_env,
  ../types,
  ../../../../nimbus/core/eip4844,
  ../../../../nimbus/common/common

type
  NewPayloads* = ref object of TestStep
    # Payload Count
    payloadCount*: int
    # Number of blob transactions that are expected to be included in the payload
    expectedIncludedBlobCount*: int
    # Blob IDs expected to be found in the payload
    expectedBlobs*: seq[BlobID]
    # Delay between FcU and GetPayload calls
    getPayloadDelay*: int
    # GetPayload modifier when requesting the new Payload
    getPayloadCustomizer*: GetPayloadCustomizer
    # ForkchoiceUpdate modifier when requesting the new Payload
    fcUOnPayloadRequest*: ForkchoiceUpdatedCustomizer
    # Extra modifications on NewPayload to potentially generate an invalid payload
    newPayloadCustomizer*: NewPayloadCustomizer
    # ForkchoiceUpdate modifier when setting the new payload as head
    fcUOnHeadSet*: ForkchoiceUpdatedCustomizer
    # Expected responses on the NewPayload call
    expectationDescription*: string

func getPayloadCount(step: NewPayloads): int =
  var payloadCount = step.payloadCount
  if payloadCount == 0:
    payloadCount = 1
  return payloadCount

proc verifyPayload(step: NewPayloads,
                   com: CommonRef,
                   client: RpcClient,
                   blobTxsInPayload: openArray[Transaction],
                   shouldOverrideBuilder: Opt[bool],
                   payload: ExecutionPayload,
                   previousPayload = Opt.none(ExecutionPayload)): bool =

  var
    parentExcessBlobGas = 0'u64
    parentBlobGasUsed   = 0'u64

  if previousPayload.isSome:
    let prevPayload = previousPayload.get
    if prevPayload.excessBlobGas.isSome:
      parentExcessBlobGas = prevPayload.excessBlobGas.get.uint64

    if prevPayload.blobGasUsed.isSome:
      parentBlobGasUsed = prevPayload.blobGasUsed.get.uint64

  let
    parent = common.BlockHeader(
      excessBlobGas: Opt.some(parentExcessBlobGas),
      blobGasUsed: Opt.some(parentBlobGasUsed)
    )
    expectedExcessBlobGas = calcExcessBlobGas(parent)

  if com.isCancunOrLater(payload.timestamp.EthTime):
    if payload.excessBlobGas.isNone:
      error "payload contains nil excessDataGas"
      return false

    if payload.blobGasUsed.isNone:
      error "payload contains nil dataGasUsed"
      return false

    if payload.excessBlobGas.get.uint64 != expectedExcessBlobGas:
      error "payload contains incorrect excessDataGas",
        want=expectedExcessBlobGas,
        have=payload.excessBlobGas.get.uint64
      return false

    if shouldOverrideBuilder.isNone:
      error "shouldOverrideBuilder was not included in the getPayload response"
      return false

    var
      totalBlobCount = 0
      expectedBlobGasPrice = getBlobBaseFee(expectedExcessBlobGas)

    for tx in blobTxsInPayload:
      let blobCount = tx.versionedHashes.len
      totalBlobCount += blobCount

      # Retrieve receipt from client
      let r = client.txReceipt(tx.rlpHash)
      let expectedBlobGasUsed = blobCount.uint64 * GAS_PER_BLOB

      r.expectBlobGasUsed(expectedBlobGasUsed)
      r.expectBlobGasPrice(expectedBlobGasPrice)

    if totalBlobCount != step.expectedIncludedBlobCount:
      error "expected blobs in transactions",
        expect=step.expectedIncludedBlobCount,
        got=totalBlobCount
      return false

    if not verifyBeaconRootStorage(client, payload):
      return false

  else:
    if payload.excessBlobGas.isSome:
      error "payload contains non-nil excessDataGas pre-fork"
      return false

    if payload.blobGasUsed.isSome:
      error "payload contains non-nil dataGasUsed pre-fork"
      return false

  return true

proc verifyBlobBundle(step: NewPayloads,
                      blobDataInPayload: openArray[BlobWrapData],
                      payload: ExecutionPayload,
                      blobBundle: BlobsBundleV1): bool =

  if blobBundle.blobs.len != blobBundle.commitments.len or
      blobBundle.blobs.len != blobBundle.proofs.len:
    error "unexpected length in blob bundle",
      blobs=len(blobBundle.blobs),
      proofs=len(blobBundle.proofs),
      kzgs=len(blobBundle.commitments)
    return false

  if len(blobBundle.blobs) != step.expectedIncludedBlobCount:
    error "expected blobs",
      expect=step.expectedIncludedBlobCount,
      get=len(blobBundle.blobs)
    return false

  # Verify that the calculated amount of blobs in the payload matches the
  # amount of blobs in the bundle
  if len(blobDataInPayload) != len(blobBundle.blobs):
    error "expected blobs in the bundle",
      expect=len(blobDataInPayload),
      get=len(blobBundle.blobs)
    return false

  for i, blobData in blobDataInPayload:
    let bundleCommitment = blobBundle.commitments[i].bytes
    let bundleBlob = blobBundle.blobs[i].bytes
    let bundleProof = blobBundle.proofs[i].bytes

    if bundleCommitment != blobData.commitment:
      error "KZG mismatch at index of the bundle", index=i
      return false

    if bundleBlob != blobData.blob:
      error "blob mismatch at index of the bundle", index=i
      return false

    if bundleProof != blobData.proof:
      error "proof mismatch at index of the bundle", index=i
      return false

  if len(step.expectedBlobs) != 0:
    # Verify that the blobs in the payload match the expected blobs
    for expectedBlob in step.expectedBlobs:
      var found = false
      for blobData in blobDataInPayload:
        if expectedBlob.verifyBlob(blobData.blob):
          found = true
          break

      if not found:
        error "could not find expected blob", expectedBlob
        return false

  return true

type
  Shadow = ref object
    p: int
    payloadCount: int
    prevPayload: ExecutionPayload

method execute*(step: NewPayloads, ctx: CancunTestContext): bool =
  # Create a new payload
  # Produce the payload
  let env = ctx.env

  var originalGetPayloadDelay = env.clMock.payloadProductionClientDelay
  if step.getPayloadDelay != 0:
    env.clMock.payloadProductionClientDelay = step.getPayloadDelay

  var shadow = Shadow(
    payloadCount: step.getPayloadCount(),
    prevPayload: env.clMock.latestPayloadBuilt
  )

  for p in 0..<shadow.payloadCount:
    shadow.p = p
    let pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
      onPayloadAttributesGenerated: proc(): bool =
        if step.fcUOnPayloadRequest != nil:
          step.fcUOnPayloadRequest.setEngineAPIVersionResolver(env.engine.com)

          var
            payloadAttributes = env.clMock.latestPayloadAttributes
            forkchoiceState   = env.clMock.latestForkchoice
            expectedError     = step.fcUOnPayloadRequest.getExpectedError()
            expectedStatus    = PayloadExecutionStatus.valid
            timestamp         = env.clMock.latestHeader.timestamp.uint64

          payloadAttributes = step.fcUOnPayloadRequest.getPayloadAttributes(payloadAttributes)
          let version = step.fcUOnPayloadRequest.forkchoiceUpdatedVersion(timestamp, Opt.some(payloadAttributes.timestamp.uint64))

          if step.fcUOnPayloadRequest.getExpectInvalidStatus():
            expectedStatus = PayloadExecutionStatus.invalid

          let r = env.engine.client.forkchoiceUpdated(version, forkchoiceState, Opt.some(payloadAttributes))
          if expectedError != 0:
            r.expectErrorCode(expectedError, step.expectationDescription)
          else:
            r.expectNoError(step.expectationDescription)
            r.expectPayloadStatus(expectedStatus)

            if r.get().payloadID.isSome:
              testCond env.clMock.addPayloadID(env.engine, r.get().payloadID.get())

        return true
      ,
      onRequestNextPayload: proc(): bool =
        # Get the next payload
        if step.getPayloadCustomizer != nil:
          step.getPayloadCustomizer.setEngineAPIVersionResolver(env.engine.com)

          var
            payloadAttributes = env.clMock.latestPayloadAttributes
            payloadID         = env.clMock.nextPayloadID
            expectedError     = step.getPayloadCustomizer.getExpectedError()
            timestamp         = payloadAttributes.timestamp.uint64
            version           = step.getPayloadCustomizer.getPayloadVersion(timestamp)

          payloadID = step.getPayloadCustomizer.getPayloadID(payloadID)

          # We are going to sleep twice because there is no way to skip the CL Mock's sleep
          let period = chronos.seconds(step.getPayloadDelay)
          waitFor sleepAsync(period)

          let r = env.engine.client.getPayload(payloadID, version)
          if expectedError != 0:
            r.expectErrorCode(expectedError, step.expectationDescription)
          else:
            r.expectNoError(step.expectationDescription)

        return true
      ,
      onGetPayload: proc(): bool =
        # Get the latest blob bundle
        var
          blobBundle = env.clMock.latestBlobsBundle
          payload    = env.clMock.latestPayloadBuilt

        if not env.engine.com.isCancunOrLater(payload.timestamp.EthTime):
          # Nothing to do
          return true

        if blobBundle.isNone:
          fatal "Error getting blobs bundle", payload=shadow.p+1, count=shadow.payloadCount
          return false

        let res = getBlobDataInPayload(ctx.txPool, payload)
        if res.isErr:
          fatal "Error retrieving blob bundle", payload=shadow.p+1, count=shadow.payloadCount, msg=res.error
          return false

        let blobData = res.get

        if not step.verifyBlobBundle(blobData.data, payload, blobBundle.get):
          fatal "Error verifying blob bundle",  payload=shadow.p+1, count=shadow.payloadCount
          return false

        return true
      ,
      onNewPayloadBroadcast: proc(): bool =
        if step.newPayloadCustomizer != nil:
          step.newPayloadCustomizer.setEngineAPIVersionResolver(env.engine.com)
          # Send a test NewPayload directive with either a modified payload or modifed versioned hashes
          var
            payload        = env.clMock.latestExecutableData
            expectedError  = step.newPayloadCustomizer.getExpectedError()
            expectedStatus = PayloadExecutionStatus.valid

          # Send a custom new payload
          payload = step.newPayloadCustomizer.customizePayload(payload)
          let
            version = step.newPayloadCustomizer.newPayloadVersion(payload.timestamp.uint64)

          if step.newPayloadCustomizer.getExpectInvalidStatus():
            expectedStatus = PayloadExecutionStatus.invalid

          let r = env.client.newPayload(version, payload)
          if expectedError != 0:
            r.expectErrorCode(expectedError, step.expectationDescription)
          else:
            r.expectNoError(step.expectationDescription)
            r.expectStatus(expectedStatus)

        if step.fcUOnHeadSet != nil:
          step.fcUOnHeadSet.setEngineAPIVersionResolver(env.engine.com)

          var
            forkchoiceState = env.clMock.latestForkchoice
            expectedError   = step.fcUOnHeadSet.getExpectedError()
            expectedStatus  = PayloadExecutionStatus.valid
            timestamp       = env.clMock.latestPayloadBuilt.timestamp.uint64
            version         = step.fcUOnHeadSet.forkchoiceUpdatedVersion(timestamp)

          if step.fcUOnHeadSet.getExpectInvalidStatus():
            expectedStatus = PayloadExecutionStatus.invalid

          forkchoiceState.headBlockHash = env.clMock.latestPayloadBuilt.blockHash

          let r = env.engine.client.forkchoiceUpdated(version, forkchoiceState)
          if expectedError != 0:
            r.expectErrorCode(expectedError, step.expectationDescription)
          else:
            r.expectNoError(step.expectationDescription)
            r.expectPayloadStatus(expectedStatus)

        return true
      ,
      onForkchoiceBroadcast: proc(): bool =
        # Verify the transaction receipts on incorporated transactions
        let payload = env.clMock.latestPayloadBuilt

        let res = getBlobDataInPayload(ctx.txPool, payload)
        if res.isErr:
          fatal "Error retrieving blob bundle", payload=shadow.p+1, count=shadow.payloadCount, msg=res.error
          return false

        let blobData = res.get
        if not step.verifyPayload(env.engine.com, env.engine.client,
                   blobData.txs, env.clMock.latestShouldOverrideBuilder,
                   payload, Opt.some(shadow.prevPayload)):
          fatal "Error verifying payload", payload=shadow.p+1, count=shadow.payloadCount
          return false

        shadow.prevPayload = env.clMock.latestPayloadBuilt
        return true
    ))

    testCond pbRes
    info "Correctly produced payload", payload=shadow.p+1, count=shadow.payloadCount

  if step.getPayloadDelay != 0:
    # Restore the original delay
    env.clMock.payloadProductionClientDelay = originalGetPayloadDelay

  return true


method description*(step: NewPayloads): string =
  #[
    TODO: Figure out if we need this.
    if step.VersionedHashes != nil {
      return fmt.Sprintf("NewPayloads: %d payloads, %d blobs expected, %s", step.getPayloadCount(), step.ExpectedIncludedBlobCount, step.VersionedHashes.Description())
  ]#
  "NewPayloads: $1 payloads, $2 blobs expected" % [
    $step.getPayloadCount(), $step.expectedIncludedBlobCount
  ]
