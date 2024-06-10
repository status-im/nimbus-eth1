# Nimbus - Portal Network
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  unittest2,
  stint,
  stew/byteutils,
  results,
  eth/[common/eth_types, rlp],
  ../../../common/common_types,
  ../../../eth_data/history_data_json_store,
  ../../../network/history/history_network

const
  dataFile = "./fluffy/tests/blocks/mainnet_blocks_selected.json"
  # Block that will be validated
  blockHashStr = "0xce8f770a56203e10afe19c7dd7e2deafc356e6cce0a560a30a85add03da56137"

suite "History Network Content Validation":
  let blockDataTable =
    readJsonType(dataFile, BlockDataTable).expect("Valid data file should parse")

  let blockData =
    try:
      blockDataTable[blockHashStr]
    except KeyError:
      raiseAssert("Block must be in test file")

  let
    blockHeaderBytes = blockData.header.hexToSeqByte()
    blockBodyBytes = blockData.body.hexToSeqByte()
    receiptsBytes = blockData.receipts.hexToSeqByte()

    blockHash = BlockHash.fromHex(blockHashStr)

    blockHeader =
      decodeRlp(blockHeaderBytes, BlockHeader).expect("Valid header should decode")
    blockBody = validateBlockBodyBytes(blockBodyBytes, blockHeader).expect(
        "Should be Valid decoded block body"
      )
    receipts = validateReceiptsBytes(receiptsBytes, blockHeader.receiptsRoot).expect(
        "Should be Valid decoded receipts"
      )

  test "Valid Header":
    check validateBlockHeaderBytes(blockHeaderBytes, blockHash).isOk()

  test "Malformed Header":
    let malformedBytes = blockHeaderBytes[10 .. blockHeaderBytes.high]

    check validateBlockHeaderBytes(malformedBytes, blockHash).isErr()

  test "Invalid Header - Different gasUsed":
    var modifiedHeader = blockHeader

    modifiedHeader.gasUsed = modifiedHeader.gasUsed + 1

    let modifiedHeaderBytes = rlp.encode(modifiedHeader)

    check validateBlockHeaderBytes(modifiedHeaderBytes, blockHash).isErr()

  test "Valid Block Body":
    check validateBlockBodyBytes(blockBodyBytes, blockHeader).isOk()

  test "Malformed Block Body":
    let malformedBytes = blockBodyBytes[10 .. blockBodyBytes.high]

    check validateBlockBodyBytes(malformedBytes, blockHeader).isErr()

  test "Invalid Block Body - Modified Transaction List":
    var modifiedBody = blockBody

    # drop first transaction
    let modifiedTransactionList =
      blockBody.transactions[1 .. blockBody.transactions.high]

    modifiedBody.transactions = modifiedTransactionList

    let modifiedBodyBytes = encode(modifiedBody)

    check validateBlockBodyBytes(modifiedBodyBytes, blockHeader).isErr()

  test "Invalid Block Body - Modified Uncles List":
    var modifiedBody = blockBody

    modifiedBody.uncles = @[]

    let modifiedBodyBytes = encode(modifiedBody)

    check validateBlockBodyBytes(modifiedBodyBytes, blockHeader).isErr()

  test "Valid Receipts":
    check validateReceiptsBytes(receiptsBytes, blockHeader.receiptsRoot).isOk()

  test "Malformed Receipts":
    let malformedBytes = receiptsBytes[10 .. receiptsBytes.high]

    check validateReceiptsBytes(malformedBytes, blockHeader.receiptsRoot).isErr()

  test "Invalid Receipts - Modified Receipts List":
    var modifiedReceipts = receipts[1 .. receipts.high]

    let modifiedReceiptsBytes = encode(modifiedReceipts)

    check validateReceiptsBytes(modifiedReceiptsBytes, blockHeader.receiptsRoot).isErr()
