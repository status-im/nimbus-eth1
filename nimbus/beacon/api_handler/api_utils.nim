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
  eth/[rlp],
  json_rpc/errors,
  nimcrypto/[hash, sha2],
  stew/[results, endians2],
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

proc computePayloadId*(blockHash: common.Hash256,
                       params: PayloadAttributes): PayloadID =
  var dest: common.Hash256
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

proc validateBlockHash*(header: common.BlockHeader,
                        gotHash: common.Hash256,
                        version: Version): Result[void, PayloadStatusV1]
                          {.gcsafe, raises: [ValueError].} =
  let wantHash = header.blockHash
  if wantHash != gotHash:
    let status = if version == Version.V1:
                   PayloadExecutionStatus.invalid_block_hash
                 else:
                   PayloadExecutionStatus.invalid

    let res = PayloadStatusV1(
      status: status,
      validationError: some("blockhash mismatch, want $1, got $2" % [
       $wantHash, $gotHash])
    )
    return err(res)

  return ok()

template toValidHash*(x: common.Hash256): Option[Web3Hash] =
  some(w3Hash x)

proc simpleFCU*(status: PayloadStatusV1): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus: status)

proc simpleFCU*(status: PayloadExecutionStatus): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus: PayloadStatusV1(status: status))

proc simpleFCU*(status: PayloadExecutionStatus,
                msg: string): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(
    payloadStatus: PayloadStatusV1(
      status: status,
      validationError: some(msg)
    )
  )

proc invalidFCU*(hash = common.Hash256()): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus:
    PayloadStatusV1(
      status: PayloadExecutionStatus.invalid,
      latestValidHash: toValidHash(hash)
    )
  )

proc validFCU*(id: Option[PayloadID],
               validHash: common.Hash256): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(
    payloadStatus: PayloadStatusV1(
      status: PayloadExecutionStatus.valid,
      latestValidHash: toValidHash(validHash)
    ),
    payloadId: id
  )

proc invalidStatus*(validHash: common.Hash256, msg: string): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.invalid,
    latestValidHash: toValidHash(validHash),
    validationError: some(msg)
  )

proc invalidStatus*(validHash = common.Hash256()): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.invalid,
    latestValidHash: toValidHash(validHash)
  )

proc acceptedStatus*(validHash: common.Hash256): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.accepted,
    latestValidHash: toValidHash(validHash)
  )

proc acceptedStatus*(): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.accepted
  )

proc validStatus*(validHash: common.Hash256): PayloadStatusV1 =
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
                      parent: common.BlockHeader,
                      ttd: DifficultyInt): common.Hash256
                       {.gcsafe, raises: [RlpError].} =
  if parent.isGenesis:
    return common.Hash256()
  let ptd = db.getScore(parent.parentHash)
  if ptd >= ttd:
    parent.blockHash
  else:
    # If the most recent valid ancestor is a PoW block,
    # latestValidHash MUST be set to ZERO
    common.Hash256()

proc invalidFCU*(com: CommonRef,
                 header: common.BlockHeader): ForkchoiceUpdatedResponse
                  {.gcsafe, raises: [RlpError].} =
  var parent: common.BlockHeader
  if not com.db.getBlockHeader(header.parentHash, parent):
    return invalidFCU(common.Hash256())

  let blockHash = latestValidHash(com.db, parent,
    com.ttd.get(high(common.BlockNumber)))
  invalidFCU(blockHash)