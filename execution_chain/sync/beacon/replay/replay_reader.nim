# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay environment

{.push raises:[].}

import
  std/net,
  pkg/[chronicles, eth/common],
  ./replay_reader/reader_unpack,
  ./replay_desc

logScope:
  topics = "replay reader"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc nextRecord*(rp: ReplayReaderRef): ReplayPayloadRef =
  ## Retrieve the next record from the dump
  while true:
    var line = rp.readLine(rp).valueOr:
      return ReplayPayloadRef(nil)
    if 0 < line.len and line[0] != '#':
      return line.unpack()

iterator records*(rp: ReplayReaderRef): ReplayPayloadRef =
  ## Iterate over all records
  while true:
    let record = rp.nextRecord()
    if record.isNil and rp.atEnd(rp):
      break
    yield record

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
