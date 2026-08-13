# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  unittest2,
  ../execution_chain/rpc/engine_ssz_types

func digestOf(b: byte): Digest =
  var d: Digest
  d.data[0] = b
  d

func kzgProofOf(b: byte): KzgProof =
  var p: KzgProof
  p.bytes[0] = b
  p

func blobOf(b: byte): Blob =
  var blob: Blob
  blob[0] = b
  blob

func withdrawalOf(index: uint64): Withdrawal =
  var w: Withdrawal
  w.index = index
  w

template roundTrip(T: typedesc, value: untyped): untyped =
  SSZ.decode(SSZ.encode(value), T)

suite "Engine SSZ API container types":
  test "Optional[T]: present/absent round trip":
    let present = optSome(42'u64)
    check present.isSome
    check present.get == 42'u64

    let absent = optNone(uint64)
    check not absent.isSome

  test "Optional[T]: SSZ encode/decode round trip":
    let decodedPresent = roundTrip(Optional[uint64], optSome(7'u64))
    check decodedPresent.isSome
    check decodedPresent.get == 7'u64

    let decodedAbsent = roundTrip(Optional[uint64], optNone(uint64))
    check not decodedAbsent.isSome

  test "StringSsz round trip":
    let s = toStringSsz("hello world")
    let decoded = roundTrip(StringSsz, s)
    check decoded.toString == "hello world"

  # taken from spec
  test "PayloadStatus: VALID with no error":
    let hash = Digest(data: [byte 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
      14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32])
    let status = PayloadStatus(
      status: uint8(PayloadStatusCode.VALID),
      latest_valid_hash: optSome(hash),
      validation_error: optNone(StringSsz))

    let encoded = SSZ.encode(status)
    check encoded.len == 41

    let decoded = SSZ.decode(encoded, PayloadStatus)
    check decoded.status == uint8(PayloadStatusCode.VALID)
    check decoded.latest_valid_hash.isSome
    check decoded.latest_valid_hash.get == hash
    check not decoded.validation_error.isSome

  # taken from spec
  test "PayloadStatus: INVALID with error":
    let status = PayloadStatus(
      status: uint8(PayloadStatusCode.INVALID),
      latest_valid_hash: optNone(Digest),
      validation_error: optSome(toStringSsz("bad state root")))

    let encoded = SSZ.encode(status)
    check encoded.len == 27

    let decoded = SSZ.decode(encoded, PayloadStatus)
    check decoded.status == uint8(PayloadStatusCode.INVALID)
    check not decoded.latest_valid_hash.isSome
    check decoded.validation_error.isSome
    check decoded.validation_error.get.toString == "bad state root"

  test "ForkchoiceState round trip":
    let fcs = ForkchoiceState(
      head_block_hash: digestOf(1) ,
      safe_block_hash: digestOf(2),
      finalized_block_hash: digestOf(3))
    let decoded = roundTrip(ForkchoiceState, fcs)
    check decoded == fcs

  test "ExecutionRequests round trip":
    let reqs = ExecutionRequests.init(@[
      ByteList[Limit MAX_BYTES_PER_EXECUTION_REQUEST].init(@[1'u8, 2, 3]),
      ByteList[Limit MAX_BYTES_PER_EXECUTION_REQUEST].init(@[4'u8, 5])])
    let decoded = roundTrip(ExecutionRequests, reqs)
    check decoded == reqs

  test "ExecutionPayloadParis (bellatrix shape) round trip":
    var payload: ExecutionPayloadParis
    payload.block_number = 123'u64
    payload.gas_limit = 30_000_000'u64

    let decoded = roundTrip(ExecutionPayloadParis, payload)
    check decoded.block_number == 123'u64
    check decoded.gas_limit == 30_000_000'u64
    check asSeq(decoded.transactions).len == 0

  test "ExecutionPayloadShanghai (capella shape) round trip, incl. withdrawals":
    var payload: ExecutionPayloadShanghai
    payload.block_number = 234'u64
    payload.withdrawals = typeof(payload.withdrawals).init(@[withdrawalOf(5'u64)])

    let decoded = roundTrip(ExecutionPayloadShanghai, payload)
    check decoded.block_number == 234'u64
    check asSeq(decoded.withdrawals).len == 1
    check asSeq(decoded.withdrawals)[0].index == 5'u64

  test "ExecutionPayloadCancun (deneb shape) round trip, incl. blob gas fields":
    var payload: ExecutionPayloadCancun
    payload.block_number = 345'u64
    payload.blob_gas_used = 100'u64
    payload.excess_blob_gas = 200'u64

    let decoded = roundTrip(ExecutionPayloadCancun, payload)
    check decoded.block_number == 345'u64
    check decoded.blob_gas_used == 100'u64
    check decoded.excess_blob_gas == 200'u64

  test "ExecutionPayloadAmsterdam (gloas shape) round trip, incl. slot_number":
    var payload: ExecutionPayloadAmsterdam
    payload.block_number = 456'u64
    payload.slot_number = Slot(789'u64)

    let decoded = roundTrip(ExecutionPayloadAmsterdam, payload)
    check decoded.block_number == 456'u64
    check decoded.slot_number == Slot(789'u64)

  test "BlobsBundleV1 round trip":
    let bundle = BlobsBundleV1(
      proofs: List[KzgProof, Limit engine_ssz_types.MAX_BLOB_COMMITMENTS_PER_BLOCK].init(@[kzgProofOf(1)]),
      blobs: List[Blob, Limit engine_ssz_types.MAX_BLOB_COMMITMENTS_PER_BLOCK].init(@[blobOf(2)]))
    let decoded = roundTrip(BlobsBundleV1, bundle)
    check decoded == bundle

  test "BlobsBundleV2 round trip, incl. cell-proofs-sized proofs list":
    let bundle = BlobsBundleV2(
      proofs: List[KzgProof, Limit (engine_ssz_types.MAX_BLOB_COMMITMENTS_PER_BLOCK * engine_ssz_types.CELLS_PER_EXT_BLOB)].init(
        @[kzgProofOf(1), kzgProofOf(2)]),
      blobs: List[Blob, Limit engine_ssz_types.MAX_BLOB_COMMITMENTS_PER_BLOCK].init(@[blobOf(3)]))
    let decoded = roundTrip(BlobsBundleV2, bundle)
    check decoded == bundle

  test "PayloadAttributesParis round trip":
    let attrs = PayloadAttributesParis(timestamp: 100'u64, prev_randao: digestOf(1))
    let decoded = roundTrip(PayloadAttributesParis, attrs)
    check decoded == attrs

  test "PayloadAttributesShanghai round trip, incl. withdrawals":
    let attrs = PayloadAttributesShanghai(
      timestamp: 200'u64,
      withdrawals: List[Withdrawal, Limit engine_ssz_types.MAX_WITHDRAWALS_PER_PAYLOAD].init(@[withdrawalOf(1'u64)]))
    let decoded = roundTrip(PayloadAttributesShanghai, attrs)
    check decoded == attrs

  test "PayloadAttributesCancun round trip, incl. parent_beacon_block_root":
    let attrs = PayloadAttributesCancun(
      timestamp: 300'u64,
      parent_beacon_block_root: digestOf(2))
    let decoded = roundTrip(PayloadAttributesCancun, attrs)
    check decoded == attrs

  test "PayloadAttributesAmsterdam round trip (slot_number, target_gas_limit)":
    let attrs = PayloadAttributesAmsterdam(
      timestamp: 1000'u64,
      slot_number: 5'u64,
      target_gas_limit: 36_000_000'u64)
    let decoded = SSZ.decode(SSZ.encode(attrs), PayloadAttributesAmsterdam)
    check decoded == attrs

  test "ExecutionPayloadEnvelopeParis round trip":
    var env: ExecutionPayloadEnvelopeParis
    env.payload.block_number = 1'u64
    let decoded = roundTrip(ExecutionPayloadEnvelopeParis, env)
    check decoded.payload.block_number == 1'u64

  test "ExecutionPayloadEnvelopeShanghai round trip":
    var env: ExecutionPayloadEnvelopeShanghai
    env.payload.block_number = 2'u64
    let decoded = roundTrip(ExecutionPayloadEnvelopeShanghai, env)
    check decoded.payload.block_number == 2'u64

  test "ExecutionPayloadEnvelopeCancun round trip, incl. parent_beacon_block_root":
    var env: ExecutionPayloadEnvelopeCancun
    env.payload.block_number = 3'u64
    env.parent_beacon_block_root = digestOf(3)
    let decoded = roundTrip(ExecutionPayloadEnvelopeCancun, env)
    check decoded.payload.block_number == 3'u64
    check decoded.parent_beacon_block_root == digestOf(3)

  test "ExecutionPayloadEnvelopePrague round trip, incl. execution_requests":
    var env: ExecutionPayloadEnvelopePrague
    env.payload.block_number = 4'u64
    env.execution_requests = ExecutionRequests.init(
      @[ByteList[Limit MAX_BYTES_PER_EXECUTION_REQUEST].init(@[9'u8])])
    let decoded = roundTrip(ExecutionPayloadEnvelopePrague, env)
    check decoded.payload.block_number == 4'u64
    check asSeq(decoded.execution_requests).len == 1

  test "ExecutionPayloadEnvelopeOsaka round trip":
    var env: ExecutionPayloadEnvelopeOsaka
    env.payload.block_number = 5'u64
    let decoded = roundTrip(ExecutionPayloadEnvelopeOsaka, env)
    check decoded.payload.block_number == 5'u64

  test "ExecutionPayloadEnvelopeAmsterdam round trip":
    var env: ExecutionPayloadEnvelopeAmsterdam
    env.payload.block_number = 6'u64
    env.payload.slot_number = Slot(11'u64)
    let decoded = roundTrip(ExecutionPayloadEnvelopeAmsterdam, env)
    check decoded.payload.block_number == 6'u64
    check decoded.payload.slot_number == Slot(11'u64)

  test "ForkchoiceUpdateParis round trip, payload_attributes present":
    let fcu = ForkchoiceUpdateParis(
      forkchoice_state: ForkchoiceState(head_block_hash: digestOf(1)),
      payload_attributes: optSome(PayloadAttributesParis(timestamp: 42'u64)))
    let decoded = roundTrip(ForkchoiceUpdateParis, fcu)
    check decoded.payload_attributes.isSome
    check decoded.payload_attributes.get.timestamp == 42'u64

  test "ForkchoiceUpdateShanghai round trip, payload_attributes absent":
    let fcu = ForkchoiceUpdateShanghai(
      forkchoice_state: ForkchoiceState(head_block_hash: digestOf(2)),
      payload_attributes: optNone(PayloadAttributesShanghai))
    let decoded = roundTrip(ForkchoiceUpdateShanghai, fcu)
    check not decoded.payload_attributes.isSome

  test "ForkchoiceUpdateCancun round trip":
    let fcu = ForkchoiceUpdateCancun(
      forkchoice_state: ForkchoiceState(head_block_hash: digestOf(3)),
      payload_attributes: optSome(PayloadAttributesCancun(timestamp: 7'u64)))
    let decoded = roundTrip(ForkchoiceUpdateCancun, fcu)
    check decoded.payload_attributes.get.timestamp == 7'u64

  test "ForkchoiceUpdateAmsterdam round trip, incl. custody_columns":
    var fcu = ForkchoiceUpdateAmsterdam(
      forkchoice_state: ForkchoiceState(head_block_hash: digestOf(4)),
      payload_attributes: optSome(PayloadAttributesAmsterdam(timestamp: 8'u64)))
    var columns: BitArray[engine_ssz_types.CELLS_PER_EXT_BLOB]
    columns[0] = true
    columns[10] = true
    fcu.custody_columns = optSome(columns)

    let decoded = roundTrip(ForkchoiceUpdateAmsterdam, fcu)
    check decoded.payload_attributes.get.timestamp == 8'u64
    check decoded.custody_columns.isSome
    check decoded.custody_columns.get[0]
    check decoded.custody_columns.get[10]
    check not decoded.custody_columns.get[1]

  test "ForkchoiceUpdateResponse: payload_id present/absent":
    let withId = ForkchoiceUpdateResponse(
      payload_status: PayloadStatus(status: uint8(PayloadStatusCode.VALID)),
      payload_id: optSome(default(ByteVector[8])))
    check roundTrip(ForkchoiceUpdateResponse, withId).payload_id.isSome

    let withoutId = ForkchoiceUpdateResponse(
      payload_status: PayloadStatus(status: uint8(PayloadStatusCode.SYNCING)),
      payload_id: optNone(ByteVector[8]))
    check not roundTrip(ForkchoiceUpdateResponse, withoutId).payload_id.isSome

  test "BuiltPayloadParis round trip":
    var built: BuiltPayloadParis
    built.payload.block_number = 1'u64
    built.block_value = 100.u256
    let decoded = roundTrip(BuiltPayloadParis, built)
    check decoded.payload.block_number == 1'u64
    check decoded.block_value == 100.u256

  test "BuiltPayloadShanghai round trip":
    var built: BuiltPayloadShanghai
    built.payload.block_number = 2'u64
    built.block_value = 200.u256
    let decoded = roundTrip(BuiltPayloadShanghai, built)
    check decoded.payload.block_number == 2'u64
    check decoded.block_value == 200.u256

  test "BuiltPayloadCancun round trip, incl. blobs_bundle and should_override_builder":
    var built: BuiltPayloadCancun
    built.payload.block_number = 3'u64
    built.blobs_bundle.blobs = List[Blob, Limit engine_ssz_types.MAX_BLOB_COMMITMENTS_PER_BLOCK].init(@[blobOf(1)])
    built.should_override_builder = true
    let decoded = roundTrip(BuiltPayloadCancun, built)
    check decoded.payload.block_number == 3'u64
    check asSeq(decoded.blobs_bundle.blobs).len == 1
    check decoded.should_override_builder == true

  test "BuiltPayloadPrague round trip, incl. execution_requests before should_override_builder":
    var built: BuiltPayloadPrague
    built.payload.block_number = 4'u64
    built.execution_requests = ExecutionRequests.init(
      @[ByteList[Limit MAX_BYTES_PER_EXECUTION_REQUEST].init(@[1'u8])])
    built.should_override_builder = false
    let decoded = roundTrip(BuiltPayloadPrague, built)
    check decoded.payload.block_number == 4'u64
    check asSeq(decoded.execution_requests).len == 1

  test "BuiltPayloadOsaka round trip, incl. BlobsBundleV2":
    var built: BuiltPayloadOsaka
    built.payload.block_number = 5'u64
    built.blobs_bundle.blobs = List[Blob, Limit engine_ssz_types.MAX_BLOB_COMMITMENTS_PER_BLOCK].init(@[blobOf(2)])
    let decoded = roundTrip(BuiltPayloadOsaka, built)
    check decoded.payload.block_number == 5'u64
    check asSeq(decoded.blobs_bundle.blobs).len == 1

  test "BuiltPayloadAmsterdam round trip":
    var built: BuiltPayloadAmsterdam
    built.payload.block_number = 6'u64
    built.payload.slot_number = Slot(12'u64)
    built.block_value = 600.u256
    let decoded = roundTrip(BuiltPayloadAmsterdam, built)
    check decoded.payload.block_number == 6'u64
    check decoded.payload.slot_number == Slot(12'u64)
    check decoded.block_value == 600.u256

  test "ExecutionPayloadBodyParis round trip":
    let body = ExecutionPayloadBodyParis(
      transactions: List[ByteList[Limit MAX_BYTES_PER_TX], Limit MAX_TXS_PER_PAYLOAD].init(
        @[ByteList[Limit MAX_BYTES_PER_TX].init(@[1'u8, 2, 3])]))
    let decoded = roundTrip(ExecutionPayloadBodyParis, body)
    check decoded == body

  test "ExecutionPayloadBodyShanghai round trip, incl. withdrawals":
    let body = ExecutionPayloadBodyShanghai(
      withdrawals: List[Withdrawal, Limit engine_ssz_types.MAX_WITHDRAWALS_PER_PAYLOAD].init(@[withdrawalOf(3'u64)]))
    let decoded = roundTrip(ExecutionPayloadBodyShanghai, body)
    check decoded == body

  test "ExecutionPayloadBodyAmsterdam round trip, incl. block_access_list":
    let body = ExecutionPayloadBodyAmsterdam(
      block_access_list: ByteList[Limit MAX_BAL_BYTES].init(@[7'u8, 8, 9]))
    let decoded = roundTrip(ExecutionPayloadBodyAmsterdam, body)
    check decoded == body

  test "BodiesByHashRequest / BodiesResponseAmsterdam round trip":
    let req = BodiesByHashRequest(block_hashes: List[Digest, Limit MAX_BODIES_REQUEST].init(
      @[digestOf(9)]))
    check roundTrip(BodiesByHashRequest, req).block_hashes.asSeq.len == 1

    let resp = BodiesResponseAmsterdam(entries: List[BodyEntryAmsterdam, Limit MAX_BODIES_REQUEST].init(
      @[BodyEntryAmsterdam(available: false), BodyEntryAmsterdam(available: true)]))
    let decodedResp = roundTrip(BodiesResponseAmsterdam, resp)
    check decodedResp.entries.asSeq.len == 2
    check decodedResp.entries.asSeq[0].available == false
    check decodedResp.entries.asSeq[1].available == true

  test "BodyEntryParis / BodiesResponseParis round trip":
    let resp = BodiesResponseParis(entries: List[BodyEntryParis, Limit MAX_BODIES_REQUEST].init(
      @[BodyEntryParis(available: true, body: ExecutionPayloadBodyParis())]))
    let decoded = roundTrip(BodiesResponseParis, resp)
    check decoded.entries.asSeq.len == 1
    check decoded.entries.asSeq[0].available == true

  test "BodyEntryShanghai / BodiesResponseShanghai round trip":
    let resp = BodiesResponseShanghai(entries: List[BodyEntryShanghai, Limit MAX_BODIES_REQUEST].init(
      @[BodyEntryShanghai(available: true, body: ExecutionPayloadBodyShanghai(
        withdrawals: List[Withdrawal, Limit engine_ssz_types.MAX_WITHDRAWALS_PER_PAYLOAD].init(@[withdrawalOf(4'u64)])))]))
    let decoded = roundTrip(BodiesResponseShanghai, resp)
    check decoded.entries.asSeq.len == 1
    check asSeq(decoded.entries.asSeq[0].body.withdrawals).len == 1

  test "BlobsRequest round trip":
    let req = BlobsRequest(versioned_hashes: List[Digest, Limit MAX_BLOBS_REQUEST].init(@[digestOf(5)]))
    let decoded = roundTrip(BlobsRequest, req)
    check decoded == req

  test "BlobsV4Request: cell-selection bitvector round trip":
    var req: BlobsV4Request
    req.versioned_hashes = List[Digest, Limit MAX_BLOBS_REQUEST].init(@[digestOf(7)])
    req.indices_bitarray[0] = true
    req.indices_bitarray[5] = true

    let decoded = roundTrip(BlobsV4Request, req)
    check decoded.versioned_hashes.asSeq.len == 1
    check decoded.indices_bitarray[0]
    check decoded.indices_bitarray[5]
    check not decoded.indices_bitarray[1]

  test "BlobAndProofV1 round trip":
    let bp = BlobAndProofV1(blob: blobOf(1), proof: kzgProofOf(2))
    let decoded = roundTrip(BlobAndProofV1, bp)
    check decoded == bp

  test "BlobAndProofV2 round trip, incl. variable-length cell-proofs list":
    let bp = BlobAndProofV2(
      blob: blobOf(3),
      proofs: List[KzgProof, Limit engine_ssz_types.CELLS_PER_EXT_BLOB].init(@[kzgProofOf(4), kzgProofOf(5)]))
    let decoded = roundTrip(BlobAndProofV2, bp)
    check decoded == bp
    check asSeq(decoded.proofs).len == 2

  test "BlobCellsAndProofs round trip, incl. per-cell nullability":
    let bcp = BlobCellsAndProofs(
      blob_cells: List[Optional[array[BYTES_PER_CELL, byte]], Limit engine_ssz_types.CELLS_PER_EXT_BLOB].init(
        @[optNone(array[BYTES_PER_CELL, byte])]),
      proofs: List[Optional[KzgProof], Limit engine_ssz_types.CELLS_PER_EXT_BLOB].init(
        @[optSome(kzgProofOf(6))]))
    let decoded = roundTrip(BlobCellsAndProofs, bcp)
    check decoded.blob_cells.asSeq.len == 1
    check not decoded.blob_cells.asSeq[0].isSome
    check decoded.proofs.asSeq.len == 1
    check decoded.proofs.asSeq[0].isSome
    check decoded.proofs.asSeq[0].get == kzgProofOf(6)

  test "BlobV1Entry / BlobsV1Response round trip":
    let resp = BlobsV1Response(entries: List[BlobV1Entry, Limit MAX_BLOBS_REQUEST].init(
      @[BlobV1Entry(available: true, contents: BlobAndProofV1(blob: blobOf(1), proof: kzgProofOf(2)))]))
    let decoded = roundTrip(BlobsV1Response, resp)
    check decoded.entries.asSeq.len == 1
    check decoded.entries.asSeq[0].contents.blob == blobOf(1)

  test "BlobV2Entry / BlobsV2Response round trip":
    let resp = BlobsV2Response(entries: List[BlobV2Entry, Limit MAX_BLOBS_REQUEST].init(
      @[BlobV2Entry(available: true, contents: BlobAndProofV2(blob: blobOf(3)))]))
    let decoded = roundTrip(BlobsV2Response, resp)
    check decoded.entries.asSeq.len == 1
    check decoded.entries.asSeq[0].contents.blob == blobOf(3)

  test "BlobV3Entry (alias of BlobV2Entry) / BlobsV3Response round trip":
    let resp = BlobsV3Response(entries: List[BlobV3Entry, Limit MAX_BLOBS_REQUEST].init(
      @[BlobV3Entry(available: false)]))
    let decoded = roundTrip(BlobsV3Response, resp)
    check decoded.entries.asSeq.len == 1
    check decoded.entries.asSeq[0].available == false

  test "BlobV4Entry / BlobsV4Response round trip":
    let resp = BlobsV4Response(entries: List[BlobV4Entry, Limit MAX_BLOBS_REQUEST].init(
      @[BlobV4Entry(available: true, contents: BlobCellsAndProofs())]))
    let decoded = roundTrip(BlobsV4Response, resp)
    check decoded.entries.asSeq.len == 1
    check decoded.entries.asSeq[0].available == true
