# Nimbus
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
  eth/common/eth_types_rlp,
  ../../../eth_data/history_data_json_store,
  ../../../network/history/[history_content, validation/historical_hashes_accumulator]

suite "Header Accumulator Root":
  test "Header Accumulator Update":
    const
      hashTreeRoots = [
        "53521984da4bbdbb011fe8a1473bf71bdf1040b14214a05cd1ce6932775bc7fa",
        "ae48c6d4e1b0a68324f346755645ba7e5d99da3dd1c38a9acd10e2fe4f43cfb4",
        "52f7bd6204be2d98cb9d09aa375b4355140e0d65744ce7b2f3ea34d8e6453572",
      ]

      dataFile = "./fluffy/tests/blocks/mainnet_blocks_1-2.json"

    let blockDataRes = readJsonType(dataFile, BlockDataTable)

    check blockDataRes.isOk()
    let blockData = blockDataRes.get()

    var headers: seq[BlockHeader]
    # Len of headers from blockdata + genesis header
    headers.setLen(blockData.len() + 1)

    headers[0] = getGenesisHeader()

    for k, v in blockData.pairs:
      let res = v.readBlockHeader()
      check res.isOk()
      let header = res.get()
      headers[header.number] = header

    var accumulator: Accumulator

    for i, hash in hashTreeRoots:
      updateAccumulator(accumulator, headers[i])

      check accumulator.hash_tree_root().data.toHex() == hashTreeRoots[i]
