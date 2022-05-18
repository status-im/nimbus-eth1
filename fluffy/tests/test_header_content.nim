# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [Defect].}

import
  std/tables,
  unittest2, stew/byteutils,
  eth/common/eth_types,
  ../network/header/header_content,
  ../populate_db

suite "Header Gossip Content":
  test "Header Accumulator Update":
    const dataFile = "./fluffy/tests/blocks/mainnet_blocks_1-2.json"
    let blockDataRes = readBlockDataTable(dataFile)

    check blockDataRes.isOk()
    let blockData = blockDataRes.get()

    var headers: seq[BlockHeader]
    headers.setLen(blockData.len())

    for k, v in blockData.pairs:
      let res = v.readBlockHeader()
      check res.isOk()
      let header = res.get()
      headers[header.blockNumber.truncate(int) - 1] = header

    var accumulator: Accumulator

    updateAccumulator(accumulator, headers[0])

    check accumulator.hash_tree_root().data.toHex() ==
      "411548579b5f6c651e6e1e56c3dc3fae6f389c663c0c910e462a4b806831fef6"

    updateAccumulator(accumulator, headers[1])

    check accumulator.hash_tree_root().data.toHex() ==
      "e8dbd17538189d9a5b77001ff80c4ff6d841ceb0a3d374d17ddc4098550f5f93"
