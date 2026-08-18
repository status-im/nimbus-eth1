# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/typetraits,
  unittest2,
  web3/execution_types,
  web3/engine_api_types,
  ../execution_chain/core/pooled_txs,
  ../execution_chain/beacon/ssz_eth_conv,
  beacon_chain/spec/engine_types as engine_ssz_types,
  ../execution_chain/rpc/engine_ssz_conv

func digestOf(b: byte): Digest =
  var d: Digest
  d.data[0] = b
  d

suite "Engine SSZ API to web3 conversions":
  test "Hash32 to Digest round trip":
    let d = digestOf(42)
    check toDigest(toHash32(d)) == d

  test "PayloadStatusV1 to PayloadStatus: VALID with hash":
    let status = PayloadStatusV1(
      status: PayloadExecutionStatus.valid,
      latestValidHash: Opt.some(toHash32(digestOf(9))))
    let sszStatus = toSsz(status)
    check sszStatus.status == uint8(PayloadStatusCode.VALID)
    check sszStatus.latest_valid_hash.isSome
    check sszStatus.latest_valid_hash.get == digestOf(9)
    check not sszStatus.validation_error.isSome

  test "PayloadStatusV1 to PayloadStatus: INVALID with error message":
    let status = PayloadStatusV1(
      status: PayloadExecutionStatus.invalid,
      validationError: Opt.some("bad state root"))
    let sszStatus = toSsz(status)
    check sszStatus.status == uint8(PayloadStatusCode.INVALID)
    check sszStatus.validation_error.isSome
    check sszStatus.validation_error.get.toString == "bad state root"

  test "PayloadStatusV1 to PayloadStatus: INVALID_BLOCK_HASH is not folded into INVALID":
    let status = PayloadStatusV1(
      status: PayloadExecutionStatus.invalid_block_hash,
      validationError: Opt.some("blockhash mismatch"))
    let sszStatus = toSsz(status)
    check sszStatus.status == uint8(PayloadStatusCode.INVALID_BLOCK_HASH)
    check sszStatus.status != uint8(PayloadStatusCode.INVALID)

  test "PayloadStatus INVALID_BLOCK_HASH round trips back through toWeb3":
    let sszStatus = engine_ssz_types.PayloadStatus(
      status: uint8(PayloadStatusCode.INVALID_BLOCK_HASH))
    let web3Status = toWeb3(sszStatus)
    check web3Status.status == PayloadExecutionStatus.invalid_block_hash

  test "WithdrawalV1 to Withdrawal":
    let w = WithdrawalV1(index: Quantity(1'u64), validatorIndex: Quantity(2'u64),
      amount: Quantity(3'u64))
    let sszW = toSsz(w)
    check sszW.index == 1'u64
    check sszW.validator_index == 2'u64
    check sszW.amount == 3'u64.Gwei

  test "web3 PayloadAttributes V4 to ForkedPayloadAttributes (Amsterdam)":
    let attrs = PayloadAttributes(
      timestamp: Quantity(1000'u64),
      prevRandao: default(Bytes32),
      suggestedFeeRecipient: default(Address),
      parentBeaconBlockRoot: Opt.some(toHash32(digestOf(5))),
      slotNumber: Opt.some(Quantity(7'u64)),
      targetGasLimit: Opt.some(Quantity(30_000_000'u64)))
    let forked = toForkedPayloadAttributes(attrs)
    check forked.fork == EngineFork.Amsterdam
    check forked.amsterdamData.timestamp == 1000'u64
    check forked.amsterdamData.parent_beacon_block_root == digestOf(5)
    check forked.amsterdamData.slot_number == 7'u64
    check forked.amsterdamData.target_gas_limit == 30_000_000'u64
    check asSeq(forked.amsterdamData.withdrawals).len == 0

  test "web3 PayloadAttributes V1 to ForkedPayloadAttributes (Paris)":
    let attrs = PayloadAttributes(
      timestamp: Quantity(500'u64),
      prevRandao: default(Bytes32),
      suggestedFeeRecipient: default(Address))
    let forked = toForkedPayloadAttributes(attrs)
    check forked.fork == EngineFork.Paris
    check forked.parisData.timestamp == 500'u64

  test "ForkedPayloadAttributes.timestamp forwarding accessor":
    let forked = ForkedPayloadAttributes(fork: EngineFork.Shanghai,
      shanghaiData: PayloadAttributesShanghai(timestamp: 42'u64))
    check forked.timestamp == 42'u64

  test "pooled_txs.BlobsBundle to engine_ssz_types.BlobsBundleV1":
    var commitment: KzgCommitment
    for i in 0 ..< 48:
      distinctBase(commitment)[i] = byte(i)
    let bundle = pooled_txs.BlobsBundle(
      wrapperVersion: WrapperVersionEIP4844,
      commitments: @[commitment],
      proofs: @[],
      blobs: @[])
    let sszBundle = sszBlobsBundleV1(bundle)
    check asSeq(sszBundle.commitments).len == 1
    check asSeq(sszBundle.commitments)[0].bytes == array[48, byte](commitment)

  test "engine_ssz_types.BlobAndProofV1 to web3 BlobAndProofV1":
    var sszEntry: engine_ssz_types.BlobAndProofV1
    sszEntry.proof.bytes[0] = 7
    var blob: array[131072, byte]
    blob[0] = 9
    sszEntry.blob = typeof(sszEntry.blob)(blob)
    let web3Entry = toWeb3(sszEntry)
    check array[48, byte](web3Entry.proof)[0] == 7
    check array[131072, byte](web3Entry.blob)[0] == 9
