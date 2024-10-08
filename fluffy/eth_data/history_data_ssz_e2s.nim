# Nimbus - Portal Network
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stew/[byteutils, io2],
  chronicles,
  results,
  eth/common/headers_rlp,
  ncli/e2store,
  ../network/history/[history_content, validation/historical_hashes_accumulator]

export results

# Reading SSZ data from files

proc readAccumulator*(
    file: string
): Result[FinishedHistoricalHashesAccumulator, string] =
  let encodedAccumulator = ?readAllFile(file).mapErr(toString)

  try:
    ok(SSZ.decode(encodedAccumulator, FinishedHistoricalHashesAccumulator))
  except SerializationError as e:
    err("Failed decoding accumulator: " & e.msg)

proc readEpochRecord*(file: string): Result[EpochRecord, string] =
  let encodedAccumulator = ?readAllFile(file).mapErr(toString)

  try:
    ok(SSZ.decode(encodedAccumulator, EpochRecord))
  except SerializationError as e:
    err("Decoding epoch accumulator failed: " & e.msg)

proc readEpochRecordCached*(file: string): Result[EpochRecordCached, string] =
  let encodedAccumulator = ?readAllFile(file).mapErr(toString)

  try:
    ok(SSZ.decode(encodedAccumulator, EpochRecordCached))
  except SerializationError as e:
    err("Decoding epoch accumulator failed: " & e.msg)

# Reading data in e2s format

const
  # Using the e2s format to store data, but without the specific structure
  # like in an era file, as we currently don't really need that.
  # See: https://github.com/status-im/nimbus-eth2/blob/stable/docs/e2store.md
  # Added one type for now, with numbers not formally specified.
  # Note:
  # Snappy compression for `ExecutionBlockHeaderRecord` only helps for the
  # first ~1M (?) block headers, after that there is no gain so we don't do it.
  ExecutionBlockHeaderRecord* = [byte 0xFF, 0x00]

proc readBlockHeaders*(file: string): Result[seq[headers.Header], string] =
  let fh = ?openFile(file, {OpenFlags.Read}).mapErr(toString)
  defer:
    discard closeFile(fh)

  var data: seq[byte]
  var blockHeaders: seq[headers.Header]
  while true:
    let header = readRecord(fh, data).valueOr:
      break

    if header.typ == ExecutionBlockHeaderRecord:
      let blockHeader =
        try:
          rlp.decode(data, headers.Header)
        except RlpError as e:
          return err("Invalid block header in " & file & ": " & e.msg)

      blockHeaders.add(blockHeader)
    else:
      warn "Skipping record, not a block header", typ = toHex(header.typ)

  ok(blockHeaders)
