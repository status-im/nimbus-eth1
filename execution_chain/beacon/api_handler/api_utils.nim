# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
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

from beacon_chain/spec/engine_types import
  EngineFork, PayloadStatus, ForkchoiceUpdateResponse, PayloadStatusCode,
  StringSsz, toStringSsz, optSome, optNone, ByteVector, Digest,
  ForkedPayloadAttributes, withForkedAttributes, asSeq
from ../ssz_eth_conv import toDigest, toHash32, ethWithdrawal

{.push gcsafe, raises:[].}

const
  engineApiTooDeepReorg* = -38006

proc update(ctx: var sha256, wd: common.Withdrawal) =
  ctx.update(toBytesBE wd.index)
  ctx.update(toBytesBE wd.validatorIndex)
  ctx.update(distinctBase wd.address)
  ctx.update(toBytesBE wd.amount)

proc computePayloadId*(blockHash: common.Hash32,
                       params: ForkedPayloadAttributes): Bytes8 =
  var dest: common.Hash32
  var ctx: sha256
  ctx.init()
  ctx.update(blockHash.data)
  withForkedAttributes(params):
    ctx.update(toBytesBE attrs.timestamp)
    ctx.update(distinctBase toHash32(attrs.prev_randao))
    ctx.update(distinctBase attrs.suggested_fee_recipient)
    when fork >= EngineFork.Shanghai:
      for wd in asSeq(attrs.withdrawals):
        ctx.update(ethWithdrawal(wd))
    when fork >= EngineFork.Cancun:
      ctx.update(distinctBase toHash32(attrs.parent_beacon_block_root))
    when fork == EngineFork.Amsterdam:
      ctx.update(toBytesBE attrs.slot_number)
  ctx.finish dest.data
  ctx.clear()
  (distinctBase result)[0..7] = dest.data[0..7]

func validateBlockHash*(header: common.Header,
                        wantHash: common.Hash32,
                        fork: EngineFork): Result[void, PayloadStatusV1]
                          {.gcsafe.} =
  let gotHash = header.computeBlockHash
  if wantHash != gotHash:
    let status = if fork == EngineFork.Paris:
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

proc simpleFCU*(status: PayloadStatus): ForkchoiceUpdateResponse =
  ForkchoiceUpdateResponse(payload_status: status)

proc simpleFCU*(status: PayloadStatusCode): ForkchoiceUpdateResponse =
  ForkchoiceUpdateResponse(payload_status: PayloadStatus(status: uint8(status)))

proc simpleFCU*(status: PayloadStatusCode,
                msg: string): ForkchoiceUpdateResponse =
  ForkchoiceUpdateResponse(
    payload_status: PayloadStatus(
      status: uint8(status),
      validation_error: optSome(toStringSsz(msg))
    )
  )

func invalidFCU*(
    validationError: string,
    hash = default(common.Hash32)): ForkchoiceUpdateResponse =
  ForkchoiceUpdateResponse(payload_status:
    PayloadStatus(
      status: uint8(PayloadStatusCode.INVALID),
      latest_valid_hash: optSome(hash.toDigest()),
      validation_error: optSome(toStringSsz(validationError))
    )
  )

proc validFCU*(id: Opt[Bytes8],
               validHash: common.Hash32): ForkchoiceUpdateResponse =
  ForkchoiceUpdateResponse(
    payload_status: PayloadStatus(
      status: uint8(PayloadStatusCode.VALID),
      latest_valid_hash: optSome(validHash.toDigest())
    ),
    payload_id:
      if id.isSome: optSome(ByteVector[8](distinctBase(id.get)))
      else: optNone(ByteVector[8])
  )

proc invalidStatus*(validHash: Opt[common.Hash32], msg: string): PayloadStatus =
  PayloadStatus(
    status: uint8(PayloadStatusCode.INVALID),
    latest_valid_hash:
      if validHash.isSome: optSome(validHash.get.toDigest())
      else: optNone(Digest),
    validation_error: optSome(toStringSsz(msg))
  )

proc invalidStatus*(validHash: common.Hash32, msg: string): PayloadStatus =
  invalidStatus(Opt.some(validHash), msg)

proc invalidStatus*(validHash = default(common.Hash32)): PayloadStatus =
  PayloadStatus(
    status: uint8(PayloadStatusCode.INVALID),
    latest_valid_hash: optSome(validHash.toDigest())
  )

proc acceptedStatus*(validHash: common.Hash32): PayloadStatus =
  PayloadStatus(
    status: uint8(PayloadStatusCode.ACCEPTED),
    latest_valid_hash: optSome(validHash.toDigest())
  )

proc acceptedStatus*(): PayloadStatus =
  PayloadStatus(
    status: uint8(PayloadStatusCode.ACCEPTED)
  )

proc validStatus*(validHash: common.Hash32): PayloadStatus =
  PayloadStatus(
    status: uint8(PayloadStatusCode.VALID),
    latest_valid_hash: optSome(validHash.toDigest())
  )

func invalidParams*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiInvalidParams,
    msg: msg
  )

func invalidForkChoiceState*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiInvalidForkchoiceState,
    msg: msg
  )

func unknownPayload*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiUnknownPayload,
    msg: msg
  )

func invalidAttr*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiInvalidPayloadAttributes,
    msg: msg
  )

func unsupportedFork*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiUnsupportedFork,
    msg: msg
  )

func tooLargeRequest*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiTooLargeRequest,
    msg: msg
  )

proc tooDeepReorg*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiTooDeepReorg,
    msg: msg
  )

func parseError*(msg: string): ref ApplicationError =
  (ref ApplicationError)(
    code: engineApiParseError,
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
                 header: Header): ForkchoiceUpdateResponse =
  let parent = chain.headerByHash(header.parentHash).valueOr:
    return invalidFCU(validationError)

  let blockHash =
    latestValidHash(chain.latestTxFrame, parent, chain.com.ttd.get(high(UInt256)))

  invalidFCU(validationError, blockHash)
