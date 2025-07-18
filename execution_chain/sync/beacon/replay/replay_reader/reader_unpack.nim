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
  std/[net, os, streams, strutils],
  pkg/[chronicles, chronos, eth/common, stew/base64, stew/byteutils],
  ./reader_gunzip,
  ../replay_desc

logScope:
  topics = "replay reader"

const
  DontQuit = low(int)
    ## To be used with `onCloseException()`

# ------------------------------------------------------------------------------
# Private mixin helpers for RLP decoder
# ------------------------------------------------------------------------------

proc read(rlp: var Rlp; T: type Hash): T {.raises:[RlpError].} =
  when sizeof(T) != sizeof(uint):
    # `castToUnsigned()` is defined in `std/private/bitops_utils` and
    # included by `std/bitops` but not exported (as of nim 2.2.4)
    {.error: "Expected that Hash is based on int".}
  Hash(int(cast[int64](rlp.read(uint64))))

proc read(rlp: var Rlp; T: type chronos.Duration): T {.raises:[RlpError].} =
  chronos.nanoseconds(cast[int64](rlp.read(uint64)))

proc read(rlp: var Rlp; T: type Port): T {.raises:[RlpError].} =
  Port(rlp.read(uint16))

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template onException(
    info: static[string];
    quitCode: static[int];
    code: untyped) =
  try:
    code
  except CatchableError as e:
    const blurb = info & "Replay stream reader exception"
    when quitCode == DontQuit:
      error blurb, error=($e.name), msg=e.msg
    else:
      fatal blurb & " -- STOP", error=($e.name), msg=e.msg
      quit(quitCode)

proc init(T: type; blob: string; recType: static[TraceRecType]; U: type): T =
  const info = "init(" & $recType & "): "
  var rlpBlob: seq[byte]
  info.onException(DontQuit):
    rlpBlob = Base64.decode(blob)
    return T(
      recType: recType,
      data:    rlp.decode(rlpBlob, U))

# ------------------------------------------------------------------------------
# Public record decoder functions
# ------------------------------------------------------------------------------

proc unpack*(line: string): ReplayPayloadRef =
  if line.len < 3:
    return ReplayPayloadRef(nil)

  var recType: TraceRecType
  if line[0].isDigit:
    let n = line[0].ord - '0'.ord
    if high(TraceRecType).ord < n:
      return ReplayPayloadRef(nil)
    recType = TraceRecType(n)

  elif line[0].isUpperAscii:
    let n = line[0].ord - 'A'.ord + 10
    if high(TraceRecType).ord < n:
      return ReplayPayloadRef(nil)
    recType = TraceRecType(n)

  else:
    return ReplayPayloadRef(nil)

  let data = line.substr(2, line.len-1)
  case recType:
  of TrtOops:
    return ReplayPayloadRef(
      recType: TrtOops)

  of TrtVersionInfo:
    return ReplayVersionInfo.init(
      data, TrtVersionInfo, TraceVersionInfo)

  # ------------------

  of TrtSyncActvFailed:
    return ReplaySyncActvFailed.init(
      data, TrtSyncActvFailed, TraceSyncActvFailed)

  of TrtSyncActivated:
    return ReplaySyncActivated.init(
      data, TrtSyncActivated, TraceSyncActivated)

  of TrtSyncHibernated:
    return ReplaySyncHibernated.init(
      data, TrtSyncHibernated, TraceSyncHibernated)

  # ------------------

  of TrtSchedDaemonBegin:
    return ReplaySchedDaemonBegin.init(
      data, TrtSchedDaemonBegin, TraceSchedDaemonBegin)

  of TrtSchedDaemonEnd:
    return ReplaySchedDaemonEnd.init(
      data, TrtSchedDaemonEnd, TraceSchedDaemonEnd)

  of TrtSchedStart:
    return ReplaySchedStart.init(
      data, TrtSchedStart, TraceSchedStart)

  of TrtSchedStop:
    return ReplaySchedStop.init(
      data, TrtSchedStop, TraceSchedStop)

  of TrtSchedPool:
    return ReplaySchedPool.init(
      data, TrtSchedPool, TraceSchedPool)

  of TrtSchedPeerBegin:
    return ReplaySchedPeerBegin.init(
      data, TrtSchedPeerBegin, TraceSchedPeerBegin)

  of TrtSchedPeerEnd:
    return ReplaySchedPeerEnd.init(
      data, TrtSchedPeerEnd, TraceSchedPeerEnd)

  # ------------------

  of TrtBeginHeaders:
    return ReplayBeginHeaders.init(
      data, TrtBeginHeaders, TraceBeginHeaders)

  of TrtGetBlockHeaders:
    return ReplayGetBlockHeaders.init(
      data, TrtGetBlockHeaders, TraceGetBlockHeaders)

  of TrtBeginBlocks:
    return ReplayBeginBlocks.init(
      data, TrtBeginBlocks, TraceBeginBlocks)

  of TrtGetBlockBodies:
    return ReplayGetBlockBodies.init(
      data, TrtGetBlockBodies, TraceGetBlockBodies)

  of TrtImportBlock:
    return ReplayImportBlock.init(
      data, TrtImportBlock, TraceImportBlock)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
