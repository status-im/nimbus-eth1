# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  unittest2,
  stint,
  eth/common/headers,
  ../../eth_data/history_data_json_store,
  ../../network/legacy_history/
    [history_content, validation/block_proof_historical_hashes_accumulator],
  ./test_history_util

suite "Historical Hashes Accumulator":
  test "Historical Hashes Accumulator Canonical Verification":
    const
      # Amount of headers to be created and added to the accumulator
      amount = mergeBlockNumber
      # Headers to test verification for.
      # Note: This test assumes at least 5 epochs
      headersToTest = [
        0,
        EPOCH_SIZE - 1,
        EPOCH_SIZE,
        EPOCH_SIZE * 2 - 1,
        EPOCH_SIZE * 2,
        EPOCH_SIZE * 3 - 1,
        EPOCH_SIZE * 3,
        EPOCH_SIZE * 3 + 1,
        int(amount) - 1,
      ]

    var headers: seq[Header]
    for i in 0 ..< amount:
      # Note: These test headers will not be a blockchain, as the parent hashes
      # are not properly filled in. That's fine however for this test, as that
      # is not the way the headers are verified with the accumulator.
      headers.add(Header(number: i, difficulty: 1.stuint(256)))

    let accumulatorRes = buildAccumulatorData(headers)
    check accumulatorRes.isOk()
    let (accumulator, epochRecords) = accumulatorRes.get()

    block: # Test valid headers
      for i in headersToTest:
        let header = headers[i]
        let proof = buildProof(header, epochRecords)
        check:
          proof.isOk()
          verifyProof(accumulator, header, proof.get())

    block: # Test invalid headers
      # Post merge block number must fail (> than latest header in accumulator)
      var proof: HistoricalHashesAccumulatorProof
      let header = Header(number: mergeBlockNumber)
      check verifyProof(accumulator, header, proof) == false

      # Test altered block headers by altering the difficulty
      for i in headersToTest:
        let proof = buildProof(headers[i], epochRecords)
        check:
          proof.isOk()
        # Alter the block header so the proof no longer matches
        let header = Header(number: i.uint64, difficulty: 2.stuint(256))

        check verifyProof(accumulator, header, proof.get()) == false

    block: # Test invalid proofs
      var proof: HistoricalHashesAccumulatorProof

      for i in headersToTest:
        check verifyProof(accumulator, headers[i], proof) == false

  test "Historical Hashes Accumulator - Not Finished":
    # Less headers than needed to finish the accumulator
    const amount = mergeBlockNumber - 1

    var headers: seq[Header]
    for i in 0 ..< amount:
      headers.add(Header(number: i, difficulty: 1.stuint(256)))

    let accumulatorRes = buildAccumulator(headers)

    check accumulatorRes.isErr()
