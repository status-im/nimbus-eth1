# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  unittest2, stew/byteutils,
  eth/common/eth_types_rlp,
  ../../../network_metadata,
  ../../../eth_data/[history_data_json_store, history_data_ssz_e2s],
  ../../../network/history/[history_content, history_network, accumulator],
  ../../test_history_util

type
  JsonPortalContent* = object
    content_key*: string
    content_value*: string

  JsonPortalContentTable* = Table[string, JsonPortalContent]

suite "History Content Encodings":
  test "HeaderWithProof Building and Encoding":
    const
      headerFile = "./vendor/portal-spec-tests/tests/mainnet/history/headers/1000001-1000010.e2s"
      accumulatorFile = "./vendor/portal-spec-tests/tests/mainnet/history/accumulator/epoch-accumulator-00122.ssz"
      headersWithProofFile = "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/1000001-1000010.json"

    let
      blockHeaders = readBlockHeaders(headerFile).valueOr:
        raiseAssert "Invalid header file: " & headerFile
      epochAccumulator = readEpochAccumulatorCached(accumulatorFile).valueOr:
        raiseAssert "Invalid epoch accumulator file: " & accumulatorFile
      blockHeadersWithProof =
        buildHeadersWithProof(blockHeaders, epochAccumulator).valueOr:
          raiseAssert "Could not build headers with proof"
      accumulator =
        try:
          SSZ.decode(finishedAccumulator, FinishedAccumulator)
        except SszError as err:
          raiseAssert "Invalid baked-in accumulator: " & err.msg


    let res = readJsonType(headersWithProofFile, JsonPortalContentTable)
    check res.isOk()
    let content = res.get()

    for i, (headerContentKey, headerWithProof) in blockHeadersWithProof:
      # Go over all content keys and headers with generated proofs and compare
      # them with the ones from the test vectors.
      let
        blockNumber = blockHeaders[i].blockNumber
        contentKeyEncoded =
          content[blockNumber.toString()].content_key.hexToSeqByte()
        contentValueEncoded =
          content[blockNumber.toString()].content_value.hexToSeqByte()

      check:
        contentKeyEncoded == headerContentKey
        contentValueEncoded == headerWithProof

      # Also run the encode/decode loopback and verification of the header
      # proofs.
      let
        contentKey = decodeSsz(
          contentKeyEncoded, ContentKey)
        contentValue = decodeSsz(
          contentValueEncoded, BlockHeaderWithProof)

      check:
        contentKey.isOk()
        contentValue.isOk()

      let blockHeaderWithProof = contentValue.get()

      let res = decodeRlp(blockHeaderWithProof.header.asSeq(), BlockHeader)
      check res.isOk()
      let header = res.get()

      check accumulator.verifyHeader(header, blockHeaderWithProof.proof).isOk()

      # Encode content
      check:
        SSZ.encode(blockHeaderWithProof) == contentValueEncoded
        encode(contentKey.get()).asSeq() == contentKeyEncoded

  test "HeaderWithProof Encoding/Decoding and Verification":
    const dataFile =
      "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/14764013.json"

    let accumulator =
      try:
        SSZ.decode(finishedAccumulator, FinishedAccumulator)
      except SszError as err:
        raiseAssert "Invalid baked-in accumulator: " & err.msg

    let res = readJsonType(dataFile, JsonPortalContentTable)
    check res.isOk()
    let content = res.get()

    for k, v in content:
      # TODO: strange assignment failure when using try/except ValueError
      # for the hexToSeqByte() here.
      let
        contentKeyEncoded = v.content_key.hexToSeqByte()
        contentValueEncoded = v.content_value.hexToSeqByte()

      # Decode content
      let
        contentKey = decodeSsz(
          contentKeyEncoded, ContentKey)
        contentValue = decodeSsz(
          contentValueEncoded, BlockHeaderWithProof)

      check:
        contentKey.isOk()
        contentValue.isOk()

      let blockHeaderWithProof = contentValue.get()

      let res = decodeRlp(blockHeaderWithProof.header.asSeq(), BlockHeader)
      check res.isOk()
      let header = res.get()

      check accumulator.verifyHeader(header, blockHeaderWithProof.proof).isOk()

      # Encode content
      check:
        SSZ.encode(blockHeaderWithProof) == contentValueEncoded
        encode(contentKey.get()).asSeq() == contentKeyEncoded

  test "Block Body Encoding/Decoding and Verification":
    const
      dataFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/bodies/14764013.json"
      headersWithProofFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/14764013.json"

    let res = readJsonType(dataFile, JsonPortalContentTable)
    check res.isOk()
    let content = res.get()

    let headersRes = readJsonType(headersWithProofFile, JsonPortalContentTable)
    check headersRes.isOk()
    let headers = headersRes.get()

    for k, v in content:
      let
        contentKeyEncoded = v.content_key.hexToSeqByte()
        contentValueEncoded = v.content_value.hexToSeqByte()

      # Get the header for validation of body
      let
        headerEncoded = headers[k].content_value.hexToSeqByte()
        headerWithProofRes = decodeSsz(
          headerEncoded, BlockHeaderWithProof)
      check headerWithProofRes.isOk()
      let headerRes = decodeRlp(
        headerWithProofRes.get().header.asSeq(), BlockHeader)
      check headerRes.isOk()
      let header = headerRes.get()

      # Decode content key
      let contentKey = decodeSsz(contentKeyEncoded, ContentKey)
      check contentKey.isOk()

      # Decode (SSZ + RLP decode step) and validate block body
      let contentValue = validateBlockBodyBytes(
        contentValueEncoded, header.txRoot, header.ommersHash)
      check contentValue.isOk()

      # Encode content and content key
      check:
        encode(contentValue.get()) == contentValueEncoded
        encode(contentKey.get()).asSeq() == contentKeyEncoded


  test "Receipts Encoding/Decoding and Verification":
    const
      dataFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/receipts/14764013.json"
      headersWithProofFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/14764013.json"

    let res = readJsonType(dataFile, JsonPortalContentTable)
    check res.isOk()
    let content = res.get()

    let headersRes = readJsonType(headersWithProofFile, JsonPortalContentTable)
    check headersRes.isOk()
    let headers = headersRes.get()

    for k, v in content:
      let
        contentKeyEncoded = v.content_key.hexToSeqByte()
        contentValueEncoded = v.content_value.hexToSeqByte()

      # Get the header for validation of receipts
      let
        headerEncoded = headers[k].content_value.hexToSeqByte()
        headerWithProofRes = decodeSsz(
          headerEncoded, BlockHeaderWithProof)
      check headerWithProofRes.isOk()
      let headerRes = decodeRlp(
        headerWithProofRes.get().header.asSeq(), BlockHeader)
      check headerRes.isOk()
      let header = headerRes.get()

      # Decode content key
      let contentKey = decodeSsz(contentKeyEncoded, ContentKey)
      check contentKey.isOk()

      # Decode (SSZ + RLP decode step) and validate receipts
      let contentValue = validateReceiptsBytes(
        contentValueEncoded, header.receiptRoot)
      check contentValue.isOk()

      # Encode content
      check:
        encode(contentValue.get()) == contentValueEncoded
        encode(contentKey.get()).asSeq() == contentKeyEncoded
