# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  unittest2,
  stew/byteutils,
  eth/common/headers_rlp,
  ../../network/network_metadata,
  ../../network/beacon/beacon_init_loader,
  ../../eth_data/[history_data_json_store, history_data_ssz_e2s],
  ../../network/legacy_history/
    [history_content, history_type_conversions, history_validation],
  ../../eth_data/yaml_utils,
  ./test_history_util

from std/os import walkDir, splitFile, PathComponent

from ../../network/beacon/beacon_chain_historical_summaries import
  HistoricalSummariesWithProof

suite "History Content Values":
  test "HeaderWithProof Building and Encoding":
    const
      headerFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers/1000001-1000010.e2s"
      accumulatorFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/accumulator/epoch-record-00122.ssz"
      headersWithProofFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/1000001-1000010.json"

    let
      blockHeaders = readBlockHeaders(headerFile).valueOr:
        raiseAssert "Invalid header file: " & headerFile
      epochRecord = readEpochRecordCached(accumulatorFile).valueOr:
        raiseAssert "Invalid epoch accumulator file: " & accumulatorFile
      blockHeadersWithProof = buildHeadersWithProof(blockHeaders, epochRecord).valueOr:
        raiseAssert "Could not build headers with proof"
      accumulators = HeaderVerifier(historicalHashes: loadAccumulator())
      networkData = loadNetworkData("mainnet")
      cfg = networkData.metadata.cfg

    let res = readJsonType(headersWithProofFile, JsonPortalContentTable)
    check res.isOk()
    let content = res.get()

    for i, (headerContentKey, headerWithProof) in blockHeadersWithProof:
      # Go over all content keys and headers with generated proofs and compare
      # them with the ones from the test vectors.
      let
        blockNumber = blockHeaders[i].number
        contentKeyEncoded = content[$blockNumber].content_key.hexToSeqByte()
        contentValueEncoded = content[$blockNumber].content_value.hexToSeqByte()

      check:
        contentKeyEncoded == headerContentKey
        contentValueEncoded == headerWithProof

      # Also run the encode/decode loopback and verification of the header
      # proofs.
      let
        contentKey = decodeSsz(contentKeyEncoded, ContentKey)
        contentValue = decodeSsz(contentValueEncoded, BlockHeaderWithProof)

      check:
        contentKey.isOk()
        contentValue.isOk()

      let blockHeaderWithProof = contentValue.get()

      let res = decodeRlp(blockHeaderWithProof.header.asSeq(), Header)
      check res.isOk()
      let header = res.get()

      check accumulators
      .verifyBlockHeaderProof(header, blockHeaderWithProof.proof, cfg)
      .isOk()

      # Encode content
      check:
        SSZ.encode(blockHeaderWithProof) == contentValueEncoded
        encode(contentKey.get()).asSeq() == contentKeyEncoded

  test "HeaderWithProof Encoding/Decoding and Verification":
    const
      testsPath = "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/"
      historicalSummaries_path =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/beacon_data/historical_summaries_at_slot_11476992.ssz"

    let historicalSummaries = readHistoricalSummaries(historicalSummaries_path).valueOr:
      raiseAssert "Cannot read historical summaries: " & error
    let cfg = loadNetworkData("mainnet").metadata.cfg

    for kind, path in walkDir(testsPath):
      if kind == pcFile and path.splitFile.ext == ".yaml":
        let
          content = YamlPortalContent.loadFromYaml(path).valueOr:
            raiseAssert "Invalid data file: " & error
          verifier = HeaderVerifier(
            historicalHashes: loadAccumulator(),
            historicalRoots: loadHistoricalRoots(),
            beaconDbCache: BeaconDbCache(
              historicalSummariesCache: Opt.some(
                # Note: incomplete but sufficient for the test
                HistoricalSummariesWithProof(historical_summaries: historicalSummaries)
              )
            ),
          )
          contentKeyEncoded = content.content_key.hexToSeqByte()
          contentValueEncoded = content.content_value.hexToSeqByte()

        # Decode content key
        let contentKeyRes = decodeSsz(contentKeyEncoded, ContentKey)
        check contentKeyRes.isOk()
        let contentKey = contentKeyRes.get()

        # Decode content value
        let contentValueRes = decodeSsz(contentValueEncoded, BlockHeaderWithProof)
        check contentValueRes.isOk()
        let blockHeaderWithProof = contentValueRes.get()

        # Verifies if block header is canonical and if it matches the hash
        # of provided content key.
        check validateCanonicalHeaderBytes(
          contentValueEncoded, contentKey.blockHeaderKey.blockHash, verifier, cfg
        )
        .isOk()

        # Re-encode content key and content value
        check:
          SSZ.encode(blockHeaderWithProof) == contentValueEncoded
          encode(contentKey).asSeq() == contentKeyEncoded

  test "PortalBlockBody (Legacy) Encoding/Decoding and Verification":
    const
      dataFile = "./vendor/portal-spec-tests/tests/mainnet/history/bodies/14764013.yaml"
      headersDataFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/14764013.yaml"

    let
      content = YamlPortalContent.loadFromYaml(dataFile).valueOr:
        raiseAssert "Invalid data file: " & error
      headerContent = YamlPortalContent.loadFromYaml(headersDataFile).valueOr:
        raiseAssert "Invalid data file: " & error

      contentKeyEncoded = content.content_key.hexToSeqByte()
      contentValueEncoded = content.content_value.hexToSeqByte()

    # Get the header for validation of body
    let
      headerEncoded = headerContent.content_value.hexToSeqByte()
      headerWithProofRes = decodeSsz(headerEncoded, BlockHeaderWithProof)
    check headerWithProofRes.isOk()
    let headerRes = decodeRlp(headerWithProofRes.get().header.asSeq(), Header)
    check headerRes.isOk()
    let header = headerRes.get()

    # Decode content key
    let contentKey = decodeSsz(contentKeyEncoded, ContentKey)
    check contentKey.isOk()

    # Decode (SSZ + RLP decode step) and validate block body
    let contentValue = validateBlockBodyBytes(contentValueEncoded, header)
    check contentValue.isOk()

    # Encode content and content key
    check:
      encode(contentValue.get()) == contentValueEncoded
      encode(contentKey.get()).asSeq() == contentKeyEncoded

  test "PortalBlockBody (Shanghai) Encoding/Decoding":
    # TODO: We don't have the header (without proof) ready here so cannot do
    # full validation for now. Add this header and then we can do like above.
    const dataFile =
      "./vendor/portal-spec-tests/tests/mainnet/history/bodies/17139055.json"

    let res = readJsonType(dataFile, JsonPortalContentTable)
    check res.isOk()
    let content = res.get()

    for k, v in content:
      let
        contentKeyEncoded = v.content_key.hexToSeqByte()
        contentValueEncoded = v.content_value.hexToSeqByte()

      # Decode content key
      let contentKey = decodeSsz(contentKeyEncoded, ContentKey)
      check contentKey.isOk()

      # Decode (SSZ + RLP decode step) and validate block body
      let contentValue = fromPortalBlockBodyBytes(contentValueEncoded)
      check contentValue.isOk()

      # Encode content and content key
      check:
        encode(contentValue.get()) == contentValueEncoded
        encode(contentKey.get()).asSeq() == contentKeyEncoded

  test "Receipts Encoding/Decoding and Verification":
    const
      dataFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/receipts/14764013.yaml"
      headersDataFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/14764013.yaml"

    let
      content = YamlPortalContent.loadFromYaml(dataFile).valueOr:
        raiseAssert "Invalid data file: " & error
      headerContent = YamlPortalContent.loadFromYaml(headersDataFile).valueOr:
        raiseAssert "Invalid data file: " & error

      contentKeyEncoded = content.content_key.hexToSeqByte()
      contentValueEncoded = content.content_value.hexToSeqByte()

    # Get the header for validation of receipts
    let
      headerEncoded = headerContent.content_value.hexToSeqByte()
      headerWithProofRes = decodeSsz(headerEncoded, BlockHeaderWithProof)
    check headerWithProofRes.isOk()
    let headerRes = decodeRlp(headerWithProofRes.get().header.asSeq(), Header)
    check headerRes.isOk()
    let header = headerRes.get()

    # Decode content key
    let contentKey = decodeSsz(contentKeyEncoded, ContentKey)
    check contentKey.isOk()

    # Decode (SSZ + RLP decode step) and validate receipts
    let contentValue = validateReceiptsBytes(contentValueEncoded, header.receiptsRoot)
    check contentValue.isOk()

    # Encode content
    check:
      encode(contentValue.get()) == contentValueEncoded
      encode(contentKey.get()).asSeq() == contentKeyEncoded

  test "Ephemeral headers Encoding/Decoding - FindContent":
    const dataFile =
      "./vendor/portal-spec-tests/tests/mainnet/history/ephemeral_headers/20000000-findcontent.yaml"

    let
      content = YamlPortalContent.loadFromYaml(dataFile).valueOr:
        raiseAssert "Invalid data file: " & error

      contentKeyEncoded = content.content_key.hexToSeqByte()
      contentValueEncoded = content.content_value.hexToSeqByte()

    # Decode content key
    let contentKey = decodeSsz(contentKeyEncoded, ContentKey)
    check contentKey.isOk()

    # Decode content value
    let contentValue = decodeSsz(contentValueEncoded, EphemeralBlockHeaderList)
    check contentValue.isOk()

    let headerList = contentValue.value()
    check headerList.len() == 2

    let headerEncoded1 = headerList[0].asSeq()
    # RLP decode and hash verify the first header
    let headerRes = validateHeaderBytes(
      headerEncoded1, contentKey.value().ephemeralBlockHeaderFindContentKey.blockHash
    )
    check headerRes.isOk()

    let parentHash = headerRes.value().parentHash

    let headerEncoded2 = headerList[1].asSeq()
    # RLP decode and hash verify the second header
    let headerRes2 = validateHeaderBytes(headerEncoded2, parentHash)
    check headerRes2.isOk()

    # Encode content
    check:
      SSZ.encode(contentValue.value()) == contentValueEncoded
      encode(contentKey.value()).asSeq() == contentKeyEncoded

  test "Ephemeral headers Encoding/Decoding - Offer":
    const dataFile =
      "./vendor/portal-spec-tests/tests/mainnet/history/ephemeral_headers/20000000-offer.yaml"

    let
      content = YamlPortalContent.loadFromYaml(dataFile).valueOr:
        raiseAssert "Invalid data file: " & error

      contentKeyEncoded = content.content_key.hexToSeqByte()
      contentValueEncoded = content.content_value.hexToSeqByte()

    # Decode content key
    let contentKey = decodeSsz(contentKeyEncoded, ContentKey)
    check contentKey.isOk()

    # Decode content value
    let contentValue = decodeSsz(contentValueEncoded, EphemeralBlockHeader)
    check contentValue.isOk()

    let headerEncoded = contentValue.value().header.asSeq()

    # Rlp decode and hash verify the header
    let headerRes = validateHeaderBytes(
      headerEncoded, contentKey.value().ephemeralBlockHeaderOfferKey.blockHash
    )
    check headerRes.isOk()

    # Encode content
    check:
      SSZ.encode(contentValue.value()) == contentValueEncoded
      encode(contentKey.value()).asSeq() == contentKeyEncoded
