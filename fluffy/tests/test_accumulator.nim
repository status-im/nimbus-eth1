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
  eth/common/eth_types_rlp,
  ../data/history_data_parser,
  ../network/history/[history_content, accumulator]

func buildProof(
    accumulator: Accumulator,
    epochAccumulators: seq[(ContentKey, EpochAccumulator)],
    header: BlockHeader):
    Result[seq[Digest], string] =
  let
    epochIndex = getEpochIndex(header)
    epochAccumulator = epochAccumulators[epochIndex][1]

    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)
    gIndex = GeneralizedIndex(epochSize*2*2 + (headerRecordIndex*2))

  return epochAccumulator.build_proof(gIndex)

suite "Header Accumulator":
  test "Header Accumulator Canonical Verification":
    const
      # Amount of headers to be created and added to the accumulator
      amount = mergeBlockNumber
      # Headers to test verification for.
      # Note: This test assumes at least 5 epochs
      headersToTest = [
        0,
        epochSize - 1,
        epochSize,
        epochSize*2 - 1,
        epochSize*2,
        epochSize*3 - 1,
        epochSize*3,
        epochSize*3 + 1,
        int(amount) - 1]

    var headers: seq[BlockHeader]
    for i in 0..<amount:
      # Note: These test headers will not be a blockchain, as the parent hashes
      # are not properly filled in. That's fine however for this test, as that
      # is not the way the headers are verified with the accumulator.
      headers.add(BlockHeader(
        blockNumber: i.stuint(256), difficulty: 1.stuint(256)))

    let
      accumulator = buildAccumulator(headers)
      epochAccumulators = buildAccumulatorData(headers)

    block: # Test valid headers
      for i in headersToTest:
        let header = headers[i]
        let proof = buildProof(accumulator, epochAccumulators, header)
        check:
          proof.isOk()
          verifyHeader(accumulator, header, proof.get()).isOk()

    block: # Test invalid headers
      # Post merge block number must fail (> than latest header in accumulator)
      let header = BlockHeader(blockNumber: mergeBlockNumber.stuint(256))
      check verifyHeader(accumulator, header, @[]).isErr()

      # Test altered block headers by altering the difficulty
      for i in headersToTest:
        let proof = buildProof(accumulator, epochAccumulators, headers[i])
        check:
          proof.isOk()
        # Alter the block header so the proof no longer matches
        let header = BlockHeader(
          blockNumber: i.stuint(256), difficulty: 2.stuint(256))

        check verifyHeader(accumulator, header, proof.get()).isErr()

    block: # Test invalid proofs
      var proof: seq[Digest]
      for i in 0..14:
        var digest: Digest
        proof.add(digest)

      for i in headersToTest:
        check verifyHeader(accumulator, headers[i], proof).isErr()

  test "Header BlockNumber to EpochAccumulator Root":
    # Note: This test assumes at least 3 epochs
    const amount = mergeBlockNumber

    var
      headerHashes: seq[Hash256] = @[]
      headers: seq[BlockHeader]

    for i in 0..<amount:
      let header = BlockHeader(blockNumber: u256(i), difficulty: u256(1))
      headers.add(header)
      headerHashes.add(header.blockHash())

    let accumulator = buildAccumulator(headers)

    # Valid response for block numbers in epoch 0
    block:
      for i in 0..<epochSize:
        let res = accumulator.getBlockEpochDataForBlockNumber(u256(i))
        check:
          res.isOk()
          res.get().epochHash == accumulator.historicalEpochs[0]

    # Valid response for block numbers in epoch 1
    block:
      for i in epochSize..<(2 * epochSize):
        let res = accumulator.getBlockEpochDataForBlockNumber(u256(i))
        check:
          res.isOk()
          res.get().epochHash == accumulator.historicalEpochs[1]

    # Valid response for block numbers in the incomplete (= last) epoch
    block:
      const startIndex = mergeBlockNumber - (mergeBlockNumber mod epochSize)
      for i in startIndex..<mergeBlockNumber:
        let res = accumulator.getBlockEpochDataForBlockNumber(u256(i))
        check:
          res.isOk()
          res.get().epochHash ==
            accumulator.historicalEpochs[preMergeEpochs - 1]

    # Error for block number at and past merge
    block:
      check:
        accumulator.getBlockEpochDataForBlockNumber(
          u256(mergeBlockNumber)).isErr()
        accumulator.getBlockEpochDataForBlockNumber(
          u256(mergeBlockNumber + 1)).isErr()
