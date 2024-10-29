# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits, strutils],
  eth/rlp,
  json_rpc/errors,
  nimcrypto/sha2,
  stew/endians2,
  results,
  ../../constants,
  ../../db/core_db,
  ../../utils/utils,
  ../../common/common,
  web3/execution_types,
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
    for wd in params.withdrawals.get:
      ctx.update(wd)
  if params.parentBeaconBlockRoot.isSome:
    ctx.update(distinctBase params.parentBeaconBlockRoot.get)
  ctx.finish dest.data
  ctx.clear()
  (distinctBase result)[0..7] = dest.data[0..7]

proc validateBlockHash*(header: common.Header,
                        wantHash: common.Hash32,
                        version: Version): Result[void, PayloadStatusV1]
                          {.gcsafe, raises: [ValueError].} =
  let gotHash = header.blockHash
  if wantHash != gotHash:
    let status = if version == Version.V1:
                   PayloadExecutionStatus.invalid_block_hash
                 else:
                   PayloadExecutionStatus.invalid

    let res = PayloadStatusV1(
      status: status,
      validationError: Opt.some("blockhash mismatch, want $1, got $2" % [
       $wantHash, $gotHash])
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

proc invalidParams*(msg: string): ref InvalidRequest =
  (ref InvalidRequest)(
    code: engineApiInvalidParams,
    msg: msg
  )

proc invalidForkChoiceState*(msg: string): ref InvalidRequest =
  (ref InvalidRequest)(
    code: engineApiInvalidForkchoiceState,
    msg: msg
  )

proc unknownPayload*(msg: string): ref InvalidRequest =
  (ref InvalidRequest)(
    code: engineApiUnknownPayload,
    msg: msg
  )

proc invalidAttr*(msg: string): ref InvalidRequest =
  (ref InvalidRequest)(
    code: engineApiInvalidPayloadAttributes,
    msg: msg
  )

proc unsupportedFork*(msg: string): ref InvalidRequest =
  (ref InvalidRequest)(
    code: engineApiUnsupportedFork,
    msg: msg
  )

proc tooLargeRequest*(msg: string): ref InvalidRequest =
  (ref InvalidRequest)(
    code: engineApiTooLargeRequest,
    msg: msg
  )

proc latestValidHash*(db: CoreDbRef,
                      parent: common.Header,
                      ttd: DifficultyInt): common.Hash32 =
  if parent.isGenesis:
    return default(common.Hash32)
  let ptd = db.getScore(parent.parentHash).valueOr(0.u256)
  if ptd >= ttd:
    parent.blockHash
  else:
    # If the most recent valid ancestor is a PoW block,
    # latestValidHash MUST be set to ZERO
    default(common.Hash32)

proc invalidFCU*(validationError: string,
                 com: CommonRef,
                 header: common.Header): ForkchoiceUpdatedResponse =
  var parent: common.Header
  if not com.db.getBlockHeader(header.parentHash, parent):
    return invalidFCU(validationError)

  let blockHash = try:
    latestValidHash(com.db, parent, com.ttd.get(high(UInt256)))
  except RlpError:
    default(common.Hash32)

  invalidFCU(validationError, blockHash)
