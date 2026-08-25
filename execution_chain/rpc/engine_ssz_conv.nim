# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[sequtils, typetraits],
  eth/common/eth_types as common,
  beacon_chain/spec/datatypes/bellatrix,
  beacon_chain/spec/datatypes/deneb,
  beacon_chain/spec/datatypes/gloas,
  web3/execution_types as web3et,
  web3/engine_api_types as web3eat,
  ../beacon/ssz_eth_conv

import beacon_chain/spec/engine_types as engine_ssz_types

export ssz_eth_conv.toHash32, ssz_eth_conv.toDigest

# NOTE: this entire file must be deprecated when json rpc is deprecated

func toSszStatus(status: PayloadExecutionStatus): uint8 =
  case status
  of PayloadExecutionStatus.valid: uint8(PayloadStatusCode.VALID)
  of PayloadExecutionStatus.invalid: uint8(PayloadStatusCode.INVALID)
  of PayloadExecutionStatus.invalid_block_hash:
    uint8(PayloadStatusCode.INVALID_BLOCK_HASH)
  of PayloadExecutionStatus.syncing: uint8(PayloadStatusCode.SYNCING)
  of PayloadExecutionStatus.accepted: uint8(PayloadStatusCode.ACCEPTED)

func toSsz*(status: PayloadStatusV1): engine_ssz_types.PayloadStatus =
  engine_ssz_types.PayloadStatus(
    status: toSszStatus(status.status),
    latest_valid_hash:
      if status.latestValidHash.isSome: optSome(toDigest(status.latestValidHash.get))
      else: optNone(Digest),
    validation_error:
      if status.validationError.isSome: optSome(toStringSsz(status.validationError.get))
      else: optNone(StringSsz))

func toWeb3Status(status: uint8): PayloadExecutionStatus =
  case PayloadStatusCode(status)
  of PayloadStatusCode.VALID: PayloadExecutionStatus.valid
  of PayloadStatusCode.INVALID: PayloadExecutionStatus.invalid
  of PayloadStatusCode.SYNCING: PayloadExecutionStatus.syncing
  of PayloadStatusCode.ACCEPTED: PayloadExecutionStatus.accepted
  of PayloadStatusCode.INVALID_BLOCK_HASH:
    PayloadExecutionStatus.invalid_block_hash

func toWeb3*(status: engine_ssz_types.PayloadStatus): PayloadStatusV1 =
  PayloadStatusV1(
    status: toWeb3Status(status.status),
    latestValidHash:
      if status.latest_valid_hash.isSome: Opt.some(toHash32(status.latest_valid_hash.get))
      else: Opt.none(Hash32),
    validationError:
      if status.validation_error.isSome: Opt.some(status.validation_error.get.toString)
      else: Opt.none(string))

func toSsz*(w: WithdrawalV1): engine_ssz_types.Withdrawal =
  engine_ssz_types.Withdrawal(
    index: uint64(w.index),
    validator_index: uint64(w.validatorIndex),
    address: w.address,
    amount: Gwei(uint64(w.amount)))

func toSsz*(state: ForkchoiceStateV1): engine_ssz_types.ForkchoiceState =
  engine_ssz_types.ForkchoiceState(
    head_block_hash: toDigest(state.headBlockHash),
    safe_block_hash: toDigest(state.safeBlockHash),
    finalized_block_hash: toDigest(state.finalizedBlockHash))

# assumes the caller has already validated that `b.len == CELLS_PER_EXT_BLOB div 8`
func toSsz*(b: openArray[byte]): BitArray[engine_ssz_types.CELLS_PER_EXT_BLOB] =
  var res: BitArray[engine_ssz_types.CELLS_PER_EXT_BLOB]
  for i in 0 ..< b.len:
    res.bytes[i] = b[i]
  res

func toForkedPayloadAttributes*(attrs: web3et.PayloadAttributes): ForkedPayloadAttributes =
  case attrs.version
  of web3et.Version.V1:
    ForkedPayloadAttributes(fork: EngineFork.Paris, parisData: PayloadAttributesParis(
      timestamp: uint64(attrs.timestamp),
      prev_randao: toDigest(common.Hash32(attrs.prevRandao)),
      suggested_fee_recipient: attrs.suggestedFeeRecipient))
  of web3et.Version.V2:
    ForkedPayloadAttributes(fork: EngineFork.Shanghai, shanghaiData: PayloadAttributesShanghai(
      timestamp: uint64(attrs.timestamp),
      prev_randao: toDigest(common.Hash32(attrs.prevRandao)),
      suggested_fee_recipient: attrs.suggestedFeeRecipient,
      withdrawals: typeof(default(PayloadAttributesShanghai).withdrawals).init(
        attrs.withdrawals.get(newSeq[WithdrawalV1]()).mapIt(toSsz(it)))))
  of web3et.Version.V3:
    ForkedPayloadAttributes(fork: EngineFork.Cancun, cancunData: PayloadAttributesCancun(
      timestamp: uint64(attrs.timestamp),
      prev_randao: toDigest(common.Hash32(attrs.prevRandao)),
      suggested_fee_recipient: attrs.suggestedFeeRecipient,
      withdrawals: typeof(default(PayloadAttributesCancun).withdrawals).init(
        attrs.withdrawals.get(newSeq[WithdrawalV1]()).mapIt(toSsz(it))),
      parent_beacon_block_root: toDigest(attrs.parentBeaconBlockRoot.get(default(Hash32)))))
  else:
    ForkedPayloadAttributes(fork: EngineFork.Amsterdam, amsterdamData: PayloadAttributesAmsterdam(
      timestamp: uint64(attrs.timestamp),
      prev_randao: toDigest(common.Hash32(attrs.prevRandao)),
      suggested_fee_recipient: attrs.suggestedFeeRecipient,
      withdrawals: typeof(default(PayloadAttributesAmsterdam).withdrawals).init(
        attrs.withdrawals.get(newSeq[WithdrawalV1]()).mapIt(toSsz(it))),
      parent_beacon_block_root: toDigest(attrs.parentBeaconBlockRoot.get(default(Hash32))),
      slot_number: uint64(attrs.slotNumber.get(default(Quantity))),
      target_gas_limit: uint64(attrs.targetGasLimit.get(default(Quantity)))))

func toWeb3*(resp: ForkchoiceUpdateResponse): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(
    payloadStatus: toWeb3(resp.payload_status),
    payloadId:
      if resp.payload_id.isSome: Opt.some(Bytes8(distinctBase(resp.payload_id.get)))
      else: Opt.none(Bytes8))

func toWeb3*(b: engine_ssz_types.BlobAndProofV1): web3eat.BlobAndProofV1 =
  web3eat.BlobAndProofV1(
    blob: web3eat.Blob(array[131072, byte](b.blob)),
    proof: web3eat.KzgProof(b.proof.bytes))

func toWeb3*(b: engine_ssz_types.BlobAndProofV2): web3eat.BlobAndProofV2 =
  var proofs: array[engine_ssz_types.CELLS_PER_EXT_BLOB, web3eat.KzgProof]
  let sszProofs = asSeq(b.proofs)
  doAssert(sszProofs.len == engine_ssz_types.CELLS_PER_EXT_BLOB)
  for i in 0 ..< engine_ssz_types.CELLS_PER_EXT_BLOB:
    proofs[i] = web3eat.KzgProof(sszProofs[i].bytes)
  web3eat.BlobAndProofV2(blob: web3eat.Blob(array[131072, byte](b.blob)), proofs: proofs)
