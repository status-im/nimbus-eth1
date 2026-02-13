# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  std/[net, syncio],
  ./replay_reader/[reader_init, reader_unpack, reader_reclog],
  ./replay_desc

export
  ReplayReaderRef,
  reader_init

type
  StopFn* = proc(): bool {.gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc nextRecord*(rp: ReplayReaderRef): ReplayPayloadRef =
  ## Retrieve the next record from the capture
  while true:
    var line = rp.readLine(rp).valueOr:
      return ReplayPayloadRef(nil)
    if 0 < line.len and line[0] != '#':
      return line.unpack()

proc captureLog*(
    rp: ReplayReaderRef;
    prt: ReplayRecLogPrintFn;
    stop: StopFn;
      ) =
  ## Cycle through capture records from `rp` and feed them to the
  ## argument `prt()`.
  var n = 0
  while not stop():
    let w = rp.nextRecord()
    if w.isNil and rp.atEnd(rp):
      break
    n.inc
    prt w.recLogToStrList(n)
  prt n.recLogToStrEnd()

proc captureLog*(
    rp: ReplayReaderRef;
    stop: StopFn;
      ) =
  ## Pretty print linewise records from the capture `rp`.
  rp.captureLog(stdout.recLogPrint(), stop)

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator records*(rp: ReplayReaderRef): ReplayPayloadRef =
  ## Iterate over all capture records
  while true:
    let record = rp.nextRecord()
    if record.isNil and rp.atEnd(rp):
      break
    yield record

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
