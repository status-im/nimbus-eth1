# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/[net, streams, typetraits],
  pkg/[chronicles, chronos, eth/common, stew/base64],
  ./trace_desc

logScope:
  topics = "beacon trace"

# ------------------------------------------------------------------------------
# Private mixin helpers for RLP encoder
# ------------------------------------------------------------------------------

proc append(w: var RlpWriter, h: Hash) =
  when sizeof(h) != sizeof(uint):
    # `castToUnsigned()` is defined in `std/private/bitops_utils` and
    # included by `std/bitops` but not exported (as of nim 2.2.4)
    {.error: "Expected that Hash is based on int".}
  w.append(cast[uint](h).uint64)

proc append(w: var RlpWriter, d: chronos.Duration) =
  w.append(cast[uint64](d.nanoseconds))

proc append(w: var RlpWriter, p: Port) =
  w.append(distinctBase p)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc toTypeInx(w: TraceRecType): string =
  if w.ord < 10:
    $w.ord
  else:
    $chr(w.ord + 'A'.ord - 10)


proc toStream(
    buddy: BeaconBuddyRef;
    trp: TraceRecType;
    blob: seq[byte];
    flush = false;
      ) =
  ## Write tracet data to output stream
  let trc = buddy.ctx.trace
  if trc.isNil:
    debug "Trace output stopped while collecting",
      peer=($buddy.peer), recType=trp
  else:
    try:
      trc.outStream.writeLine trp.toTypeInx & " " & Base64.encode(blob)
      trc.outStream.flush()
    except CatchableError as e:
      warn "Error writing trace data", peer=($buddy.peer), recType=trp,
        recSize=blob.len, error=($e.name), msg=e.msg

proc toStream(
    ctx: BeaconCtxRef;
    trp: TraceRecType;
    blob: seq[byte];
    flush = false;
      ) =
  ## Variant of `toStream()` for `ctx` rather than `buddy`
  let trc = ctx.trace
  if trc.isNil:
    debug "Trace output stopped while collecting", recType=trp
  else:
    try:
      trc.outStream.writeLine trp.toTypeInx & " " & Base64.encode(blob)
      trc.outStream.flush()
    except CatchableError as e:
      warn "Error writing trace data", recType=trp,
        recSize=blob.len, error=($e.name), msg=e.msg

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc traceWrite*(ctx: BeaconCtxRef; w: TraceVersionInfo) =
  ctx.toStream(TrtVersionInfo, rlp.encode w)

# -------------

proc traceWrite*(ctx: BeaconCtxRef; w: TraceSyncActvFailed) =
  ctx.toStream(TrtSyncActvFailed, rlp.encode w)

proc traceWrite*(ctx: BeaconCtxRef; w: TraceSyncActivated) =
  ctx.toStream(TrtSyncActivated, rlp.encode w)

proc traceWrite*(ctx: BeaconCtxRef; w: TraceSyncHibernated) =
  ctx.toStream(TrtSyncHibernated, rlp.encode w)

# -------------

proc traceWrite*(ctx: BeaconCtxRef; w: TraceSchedDaemonBegin) =
  ctx.toStream(TrtSchedDaemonBegin, rlp.encode w)

proc traceWrite*(ctx: BeaconCtxRef; w: TraceSchedDaemonEnd) =
  ctx.toStream(TrtSchedDaemonEnd, rlp.encode w)

proc traceWrite*(buddy: BeaconBuddyRef; w: TraceSchedStart) =
  buddy.toStream(TrtSchedStart, rlp.encode w)

proc traceWrite*(buddy: BeaconBuddyRef; w: TraceSchedStop) =
  buddy.toStream(TrtSchedStop, rlp.encode w)

proc traceWrite*(buddy: BeaconBuddyRef; w: TraceSchedPool) =
  buddy.toStream(TrtSchedPool, rlp.encode w)

proc traceWrite*(buddy: BeaconBuddyRef; w: TraceSchedPeerBegin) =
  buddy.toStream(TrtSchedPeerBegin, rlp.encode w)

proc traceWrite*(buddy: BeaconBuddyRef; w: TraceSchedPeerEnd) =
  buddy.toStream(TrtSchedPeerEnd, rlp.encode w)

# -------------

proc traceWrite*(buddy: BeaconBuddyRef; w: TraceGetBlockHeaders) =
  buddy.toStream(TrtGetBlockHeaders, rlp.encode w)

proc traceWrite*(buddy: BeaconBuddyRef; w: TraceGetBlockBodies) =
  buddy.toStream(TrtGetBlockBodies, rlp.encode w)

proc traceWrite*(ctx: BeaconCtxRef; w: TraceImportBlock) =
  ctx.toStream(TrtImportBlock, rlp.encode w)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
