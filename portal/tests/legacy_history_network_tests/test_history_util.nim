# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  stew/io2,
  eth/common/headers,
  ../../network/legacy_history/history_content,
  ../../network/legacy_history/validation/
    [block_proof_historical_summaries, block_proof_historical_hashes_accumulator]

from eth/rlp import computeRlpHash

export results, block_proof_historical_hashes_accumulator, history_content

proc buildHeadersWithProof*(
    blockHeaders: seq[Header], epochRecord: EpochRecordCached
): Result[seq[(seq[byte], seq[byte])], string] =
  var blockHeadersWithProof: seq[(seq[byte], seq[byte])]
  for header in blockHeaders:
    if header.isPreMerge():
      let
        content = ?buildHeaderWithProof(header, epochRecord)
        contentKey = ContentKey(
          contentType: blockHeader,
          blockHeaderKey: BlockKey(blockHash: header.computeRlpHash()),
        )

      blockHeadersWithProof.add((encode(contentKey).asSeq(), SSZ.encode(content)))

  ok(blockHeadersWithProof)

func buildAccumulator*(
    headers: seq[Header]
): Result[FinishedHistoricalHashesAccumulator, string] =
  var accumulator: HistoricalHashesAccumulator
  for header in headers:
    updateAccumulator(accumulator, header)

    if header.number == mergeBlockNumber - 1:
      return ok(finishAccumulator(accumulator))

  err("Not enough headers provided to finish the accumulator")

func buildAccumulatorData*(
    headers: seq[Header]
): Result[(FinishedHistoricalHashesAccumulator, seq[EpochRecord]), string] =
  var accumulator: HistoricalHashesAccumulator
  var epochRecords: seq[EpochRecord]
  for header in headers:
    updateAccumulator(accumulator, header)

    if accumulator.currentEpoch.len() == EPOCH_SIZE:
      epochRecords.add(accumulator.currentEpoch)

    if header.number == mergeBlockNumber - 1:
      epochRecords.add(accumulator.currentEpoch)

      return ok((finishAccumulator(accumulator), epochRecords))

  err("Not enough headers provided to finish the accumulator")

func buildProof*(
    header: Header, epochRecords: seq[EpochRecord]
): Result[HistoricalHashesAccumulatorProof, string] =
  let epochIndex = getEpochIndex(header)
  doAssert(epochIndex < uint64(epochRecords.len()))
  let epochRecord = epochRecords[epochIndex]

  buildProof(header, epochRecord)

func buildHeaderWithProof*(
    header: Header, epochRecords: seq[EpochRecord]
): Result[BlockHeaderWithProof, string] =
  ## Construct the accumulator proof for a specific header.
  ## Returns the block header with the proof
  if header.isPreMerge():
    let epochIndex = getEpochIndex(header)
    doAssert(epochIndex < uint64(epochRecords.len()))
    let epochRecord = epochRecords[epochIndex]

    buildHeaderWithProof(header, epochRecord)
  else:
    err("Cannot build accumulator proof for post merge header")

func buildHeadersWithProof*(
    headers: seq[Header], epochRecords: seq[EpochRecord]
): Result[seq[BlockHeaderWithProof], string] =
  var headersWithProof: seq[BlockHeaderWithProof]
  for header in headers:
    headersWithProof.add(?buildHeaderWithProof(header, epochRecords))

  ok(headersWithProof)

proc toString(v: IoErrorCode): string =
  try:
    ioErrorMsg(v)
  except Exception as e:
    raiseAssert e.msg

# Testing only proc as in the real network the historical_summaries are
# retrieved from the network.
proc readHistoricalSummaries*(file: string): Result[HistoricalSummaries, string] =
  let encodedHistoricalSummaries = ?readAllFile(file).mapErr(toString)

  try:
    ok(SSZ.decode(encodedHistoricalSummaries, HistoricalSummaries))
  except SerializationError as err:
    err("Failed decoding historical_summaries: " & err.msg)
