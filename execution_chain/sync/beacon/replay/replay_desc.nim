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
  std/streams,
  pkg/chronos,
  ../trace/trace_desc,
  ./replay_reader/reader_desc,
  ./replay_runner/runner_desc

export
  reader_desc,
  runner_desc,
  trace_desc

const
  ReplayBaseHandlersID* = 2
  ReplayOverlayHandlersID* = 20

  replayWaitForCompletion* = chronos.milliseconds(100)
    ## Wait for other pseudo/async thread to have completed something

  replayWaitMuted* = chronos.milliseconds(200)
    ## Some handlers are muted, but keep them in a waiting loop so
    ## the system can terminate

type
  ReplayBaseHandlersRef* = ref object of BeaconHandlersRef
    ## Extension for caching state so that the replay start can be
    ## synchronised with, e.g. after the syncer has started
    strm*: Stream

  ReplayRef* = ref object of BeaconHandlersRef
    reader*: ReplayReaderRef            ## Input records
    backup*: BeaconHandlersRef          ## Can restore previous handlers
    runner*: ReplayRunnerRef            ## Replay descriptor


  ReplayPayloadRef* = ref object of RootRef
    ## Decoded payload base record
    recType*: TraceRecType

  ReplayVersionInfo* = ref object of ReplayPayloadRef
    data*: TraceVersionInfo

  # -------------

  ReplaySyncActvFailed* = ref object of ReplayPayloadRef
    data*: TraceSyncActvFailed

  ReplaySyncActivated* = ref object of ReplayPayloadRef
    data*: TraceSyncActivated

  ReplaySyncHibernated* = ref object of ReplayPayloadRef
    data*: TraceSyncHibernated

  # -------------

  ReplaySchedDaemonBegin* = ref object of ReplayPayloadRef
    data*: TraceSchedDaemonBegin

  ReplaySchedDaemonEnd* = ref object of ReplayPayloadRef
    data*: TraceSchedDaemonEnd

  ReplaySchedStart* = ref object of ReplayPayloadRef
    data*: TraceSchedStart

  ReplaySchedStop* = ref object of ReplayPayloadRef
    data*: TraceSchedStop

  ReplaySchedPool* = ref object of ReplayPayloadRef
    data*: TraceSchedPool

  ReplaySchedPeerBegin* = ref object of ReplayPayloadRef
    data*: TraceSchedPeerBegin

  ReplaySchedPeerEnd* = ref object of ReplayPayloadRef
    data*: TraceSchedPeerEnd

  # -------------

  ReplayGetBlockHeaders* = ref object of ReplayPayloadRef
    data*: TraceGetBlockHeaders

  ReplayGetBlockBodies* = ref object of ReplayPayloadRef
    data*: TraceGetBlockBodies

  ReplayImportBlock* = ref object of ReplayPayloadRef
    data*: TraceImportBlock

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func replay*(ctx: BeaconCtxRef): ReplayRef =
  ## Getter, get replay descriptor (if any)
  if ctx.handler.version == 20:
    return ctx.handler.ReplayRef

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
