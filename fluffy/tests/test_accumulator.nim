# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [Defect].}

import
  unittest2, stint, stew/byteutils,
  eth/common/eth_types,
  ../populate_db,
  ../network/history/accumulator

suite "Header Accumulator":
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

  test "Header Accumulator Proofs":
    const
      # Amount of headers to be created and added to the accumulator
      amount = 25000
      # Headers to test verification for
      headersToTest = [
        0,
        epochSize - 1,
        epochSize,
        epochSize*2 - 1,
        epochSize*2,
        epochSize*3 - 1,
        epochSize*3,
        epochSize*3 + 1,
        amount - 1]

    var headers: seq[BlockHeader]
    for i in 0..<amount:
      # Note: These test headers will not be a blockchain, as the parent hashes
      # are not properly filled in. That's fine however for this test, as that
      # is not the way the headers are verified with the accumulator.
      headers.add(BlockHeader(
        blockNumber: i.stuint(256), difficulty: 1.stuint(256)))

    let db = AccumulatorDB.new("", inMemory = true)

    db.buildAccumulator(headers)

    let accumulatorOpt = db.getAccumulator()
    check accumulatorOpt.isSome()
    let accumulator = accumulatorOpt.get()

    block: # Test valid headers
      for i in headersToTest:
        let header = headers[i]
        let proofOpt =
          if header.inCurrentEpoch(accumulator):
            none(seq[Digest])
          else:
            let proof = db.buildProof(header)
            check proof.isOk()

            some(proof.get())

        check db.verifyHeader(header, proofOpt).isOk()

    block: # Test some invalid headers
      # Test a header with block number > than latest in accumulator
      let header = BlockHeader(blockNumber: 25000.stuint(256))
      check db.verifyHeader(header, none(seq[Digest])).isErr()

      # Test different block headers by altering the difficulty
      for i in headersToTest:
        let header = BlockHeader(
          blockNumber: i.stuint(256), difficulty: 2.stuint(256))

        check db.verifyHeader(header, none(seq[Digest])).isErr()
