# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [Defect].}

import
  unittest2, stint,
  eth/common/eth_types,
  ../network/header/accumulator

suite "Header Accumulator":
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
