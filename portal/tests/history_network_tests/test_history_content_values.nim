# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  unittest2,
  results,
  stew/byteutils,
  ../../common/common_types,
  ../../eth_history/yaml_utils,
  ../../tools/eth_data_exporter/el_data_exporter,
  ../../network/history/history_validation

from std/os import walkDir, splitFile, PathComponent

const testsPath = "./vendor/portal-spec-tests/tests/mainnet/history/block_data/"

suite "History Network Content Values":
  test "BlockBody and Receipts Encoding/Decoding and Verification":
    for kind, path in walkDir(testsPath):
      if kind == pcFile and path.splitFile.ext == ".yaml":
        let
          blockData = BlockData.loadFromYaml(path).valueOr:
            raiseAssert "Cannot read test vector: " & error

          headerEncoded = blockData.header.hexToSeqByte()
          bodyEncoded = blockData.body.hexToSeqByte()

        let header = decodeRlp(headerEncoded, Header).expect("Valid header")

        let contentKey = blockBodyContentKey(header.number)
        check validateContent(contentKey, bodyEncoded, header).isOk()

        let contentValue = decodeRlp(bodyEncoded, BlockBody)
        check contentValue.isOk()
        check rlp.encode(contentValue.get()) == bodyEncoded

  test "Receipts Encoding/Decoding and Verification":
    for kind, path in walkDir(testsPath):
      if kind == pcFile and path.splitFile.ext == ".yaml":
        let
          blockData = BlockData.loadFromYaml(path).valueOr:
            raiseAssert "Cannot read test vector: " & error

          headerEncoded = blockData.header.hexToSeqByte()
          receiptsEncoded = blockData.receipts.hexToSeqByte()

        let header = decodeRlp(headerEncoded, Header).expect("Valid header")

        let contentKey = receiptsContentKey(header.number)
        check validateContent(contentKey, receiptsEncoded, header).isOk()

        let contentValue = decodeRlp(receiptsEncoded, StoredReceipts)
        check contentValue.isOk()
        check rlp.encode(contentValue.get()) == receiptsEncoded
