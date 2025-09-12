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
  ReplaySetupID* = 2                    ## Phase 1 layout ID, prepare
  ReplayRunnerID* = 20                  ## Phase 2 layout ID, full execution

  ReplayTypeLabel* = block:
    var a: array[TraceRecType,string]
    a[TraceRecType(0)] =  "=Oops"
    a[VersionInfo] =      "=Version"
    a[SyncActvFailed] =   "=ActvFailed"
    a[SyncActivated] =    "=Activated"
    a[SyncHibernated] =   "=Suspended"
    a[SchedStart] =       "=StartPeer"
    a[SchedStop] =        "=StopPeer"
    a[SchedPool] =        "=Pool"
    a[SchedDaemonBegin] = "+Daemon"
    a[SchedDaemonEnd] =   "-Daemon"
    a[SchedPeerBegin] =   "+Peer"
    a[SchedPeerEnd] =     "-Peer"
    a[FetchHeaders] =     "=HeadersFetch"
    a[SyncHeaders] =      "=HeadersSync"
    a[FetchBodies] =      "=BodiesFetch"
    a[SyncBodies] =       "=BodiesSync"
    a[ImportBlock] =      "=BlockImport"
    a[SyncBlock] =        "=BlockSync"
    for w in a:
      doAssert 0 < w.len
    a

type
  ReplayStopIfFn* = proc(): bool {.gcsafe, raises: [].}
    ## Loop control directive for runner/dispatcher

  ReplayEndUpFn* = proc() {.gcsafe, raises: [].}
    ## Terminator control directive for runner/dispatcher

  ReplayRef* = ref object of BeaconHandlersSyncRef
    ## Overlay handlers extended by descriptor data for caching replay state
    ctx*: BeaconCtxRef                  ## Parent context
    captStrm*: Stream                   ## Input stream, capture file
    fakeImport*: bool                   ## No database import if `true`
    stopQuit*: bool                     ## Quit after replay
    backup*: BeaconHandlersRef          ## Can restore previous handlers
    reader*: ReplayReaderRef            ## Input records
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

  ReplayFetchHeaders* = ref object of ReplayPayloadRef
    data*: TraceFetchHeaders

  ReplaySyncHeaders* = ref object of ReplayPayloadRef
    data*: TraceSyncHeaders


  ReplayFetchBodies* = ref object of ReplayPayloadRef
    data*: TraceFetchBodies

  ReplaySyncBodies* = ref object of ReplayPayloadRef
    data*: TraceSyncBodies


  ReplayImportBlock* = ref object of ReplayPayloadRef
    data*: TraceImportBlock

  ReplaySyncBlock* = ref object of ReplayPayloadRef
    data*: TraceSyncBlock

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func replay*(ctx: BeaconCtxRef): ReplayRef =
  ## Getter, get replay descriptor (if any)
  if ctx.handler.version == ReplayRunnerID:
    return ctx.handler.ReplayRef

template replayLabel*(w: untyped): string =
  ## Static getter, retrieve replay type label
  ReplayTypeLabel[(typeof w).toTraceRecType]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
