# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits],
  web3/execution_types,
  json_rpc/errors,
  nimcrypto/sha2,
  stew/endians2,
  results,
  ../../constants,
  ../../db/core_db,
  ../../utils/utils,
  ../../common/common,
  ../../core/chain,
  ../web3_eth_conv

{.push gcsafe, raises:[].}

proc update(ctx: var sha256, wd: WithdrawalV1) =
  ctx.update(toBytesBE distinctBase wd.index)
  ctx.update(toBytesBE distinctBase wd.validatorIndex)
  ctx.update(distinctBase wd.address)
  ctx.update(toBytesBE distinctBase wd.amount)

proc computePayloadId*(blockHash: common.Hash32,
                       params: PayloadAttributes): Bytes8 =
  var dest: common.Hash32
  var ctx: sha256
  ctx.init()
  ctx.update(blockHash.data)
  ctx.update(toBytesBE distinctBase params.timestamp)
  ctx.update(distinctBase params.prevRandao)
  ctx.update(distinctBase params.suggestedFeeRecipient)
  if params.withdrawals.isSome:
    for wd in params.withdrawals.value:
      ctx.update(wd)
  if params.parentBeaconBlockRoot.isSome:
    ctx.update(distinctBase params.parentBeaconBlockRoot.value)
  ctx.finish dest.data
  ctx.clear()
  (distinctBase result)[0..7] = dest.data[0..7]

proc validateBlockHash*(header: common.Header,
                        wantHash: common.Hash32,
                        version: Version): Result[void, PayloadStatusV1]
                          {.gcsafe.} =
  let gotHash = header.computeBlockHash
  if wantHash != gotHash:
    let status = if version == Version.V1:
                   PayloadExecutionStatus.invalid_block_hash
                 else:
                   PayloadExecutionStatus.invalid

    let res = PayloadStatusV1(
      status: status,
      validationError: Opt.some("blockhash mismatch, want " &
        $wantHash & ", got " & $gotHash)
    )
    return err(res)

  return ok()

template toValidHash*(x: common.Hash32): Opt[Hash32] =
  Opt.some(x)

proc simpleFCU*(status: PayloadStatusV1): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus: status)

proc simpleFCU*(status: PayloadExecutionStatus): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus: PayloadStatusV1(status: status))

proc simpleFCU*(status: PayloadExecutionStatus,
                msg: string): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(
    payloadStatus: PayloadStatusV1(
      status: status,
      validationError: Opt.some(msg)
    )
  )

proc invalidFCU*(
    validationError: string,
    hash = default(common.Hash32)): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus:
    PayloadStatusV1(
      status: PayloadExecutionStatus.invalid,
      latestValidHash: toValidHash(hash),
      validationError: Opt.some validationError
    )
  )

proc validFCU*(id: Opt[Bytes8],
               validHash: common.Hash32): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(
    payloadStatus: PayloadStatusV1(
      status: PayloadExecutionStatus.valid,
      latestValidHash: toValidHash(validHash)
    ),
    payloadId: id
  )

proc invalidStatus*(validHash: common.Hash32, msg: string): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.invalid,
    latestValidHash: toValidHash(validHash),
    validationError: Opt.some(msg)
  )

proc invalidStatus*(validHash = default(common.Hash32)): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.invalid,
    latestValidHash: toValidHash(validHash)
  )

proc acceptedStatus*(validHash: common.Hash32): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.accepted,
    latestValidHash: toValidHash(validHash)
  )

proc acceptedStatus*(): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.accepted
  )

proc validStatus*(validHash: common.Hash32): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.valid,
    latestValidHash: toValidHash(validHash)
  )

proc invalidParams*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiInvalidParams,
    msg: msg
  )

proc invalidForkChoiceState*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiInvalidForkchoiceState,
    msg: msg
  )

proc unknownPayload*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiUnknownPayload,
    msg: msg
  )

proc invalidAttr*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiInvalidPayloadAttributes,
    msg: msg
  )

proc unsupportedFork*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiUnsupportedFork,
    msg: msg
  )

proc tooLargeRequest*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiTooLargeRequest,
    msg: msg
  )

proc latestValidHash*(txFrame: CoreDbTxRef,
                      parent: Header,
                      ttd: DifficultyInt): Hash32 =
  if parent.isGenesis:
    return default(Hash32)
  # TODO shouldn't this be in forkedchainref?
  let ptd = txFrame.getScore(parent.parentHash).valueOr(0.u256)
  if ptd >= ttd:
    parent.computeBlockHash
  else:
    # If the most recent valid ancestor is a PoW block,
    # latestValidHash MUST be set to ZERO
    default(Hash32)

proc invalidFCU*(validationError: string,
                 chain: ForkedChainRef,
                 header: Header): ForkchoiceUpdatedResponse =
  let parent = chain.headerByHash(header.parentHash).valueOr:
    return invalidFCU(validationError)

  let blockHash =
    latestValidHash(chain.latestTxFrame, parent, chain.com.ttd.get(high(UInt256)))

  invalidFCU(validationError, blockHash)
