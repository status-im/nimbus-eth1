# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/streams,
  pkg/[chronicles, chronos, json_serialization],
  pkg/json_serialization/pkg/results as json_results,
  pkg/eth/common/eth_types_json_serialization as json_eth_types,
  ../trace_desc

export
  json_eth_types,
  json_results,
  json_serialization

logScope:
  topics = "beacon trace"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc toStream(ctx: BeaconCtxRef; trp: TraceRecType; data: string) =
  ## Write tracer data to output stream
  let trc = ctx.trace
  if trc.isNil:
    debug "Trace output stopped while collecting", recType=trp
  else:
    try:
      trc.outStream.writeLine data
      trc.outStream.flush()
    except CatchableError as e:
      warn "Error writing trace data", recType=trp,
        recSize=data.len, error=($e.name), msg=e.msg

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc writeValue*(
    w: var JsonWriter;
    v: chronos.Duration;
      ) {.raises: [IOError].} =
  ## Json writer mixin avoiding `{"value": NNN}` encapsulation
  w.writeValue(cast[uint64](v.nanoseconds))

template traceWrite*(dsc: BeaconCtxRef|BeaconPeerRef; capt: untyped) =
  type T = typeof capt
  const trp = T.toTraceRecType
  when dsc is BeaconCtxRef:
    dsc.toStream(trp, Json.encode(JTraceRecord[T](kind: trp, bag: capt)))
  else:
    dsc.ctx.toStream(trp, Json.encode(JTraceRecord[T](kind: trp, bag: capt)))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
