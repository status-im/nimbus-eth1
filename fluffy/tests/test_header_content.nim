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
    const
      hashTreeRoots = [
        "b629833240bb2f5eabfb5245be63d730ca4ed30d6a418340ca476e7c1f1d98c0",
        "00cbebed829e1babb93f2300bebe7905a98cb86993c7fc09bb5b04626fd91ae5",
        "88cce8439ebc0c1d007177ffb6831c15c07b4361984cc52235b6fd728434f0c7"]

      dataFile = "./fluffy/tests/blocks/mainnet_blocks_1-2.json"

    let blockDataRes = readBlockDataTable(dataFile)

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
      headers[header.blockNumber.truncate(int)] = header

    var accumulator: Accumulator

    for i, hash in hashTreeRoots:
      updateAccumulator(accumulator, headers[i])

      check accumulator.hash_tree_root().data.toHex() == hashTreeRoots[i]
