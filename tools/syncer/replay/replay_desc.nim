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
  ../trace/trace_desc,
  ./replay_reader/reader_desc

export
  reader_desc,
  trace_desc

const
  ReplaySetupID* = 2                    ## Phase 1 layout ID, prepare
  ReplayRunnerID* = 20                  ## Phase 2 layout ID, full execution

type
  ReplayStopIfFn* = proc(): bool {.gcsafe, raises: [].}
    ## Loop control directive for runner/dispatcher

  ReplayEndUpFn* = proc() {.gcsafe, raises: [].}
    ## Terminator control directive for runner/dispatcher

  ReplayGetPeerFn* = GetPeerFn[BeaconCtxData,BeaconBuddyData]
    ## Shortcut

  ReplayGetPeersFn* = GetPeersFn[BeaconCtxData,BeaconBuddyData]
    ## Shortcut

  ReplayRef* = ref object of BeaconHandlersSyncRef
    ## Overlay handlers extended by descriptor data for caching replay state
    ctx*: BeaconCtxRef                  ## Parent context
    captStrm*: Stream                   ## Input stream, capture file
    fakeImport*: bool                   ## No database import if `true`
    stopQuit*: bool                     ## Quit after replay
    backup*: BeaconHandlersRef          ## Can restore previous handlers
    reader*: ReplayReaderRef            ## Input records
    getPeerSave*: ReplayGetPeerFn       ## Additionsl restore settings

  ReplayPayloadRef* = ref object of RootRef
    ## Decoded payload base record
    recType*: TraceRecType

  ReplayVersionInfo* = ref object of ReplayPayloadRef
    bag*: TraceVersionInfo

  ReplaySyncActivated* = ref object of ReplayPayloadRef
    bag*: TraceSyncActivated

  ReplaySyncHibernated* = ref object of ReplayPayloadRef
    bag*: TraceSyncHibernated

  # -------------

  ReplaySchedDaemonBegin* = ref object of ReplayPayloadRef
    bag*: TraceSchedDaemonBegin

  ReplaySchedDaemonEnd* = ref object of ReplayPayloadRef
    bag*: TraceSchedDaemonEnd

  ReplaySchedStart* = ref object of ReplayPayloadRef
    bag*: TraceSchedStart

  ReplaySchedStop* = ref object of ReplayPayloadRef
    bag*: TraceSchedStop

  ReplaySchedPool* = ref object of ReplayPayloadRef
    bag*: TraceSchedPool

  ReplaySchedPeerBegin* = ref object of ReplayPayloadRef
    bag*: TraceSchedPeerBegin

  ReplaySchedPeerEnd* = ref object of ReplayPayloadRef
    bag*: TraceSchedPeerEnd

  # -------------

  ReplayFetchHeaders* = ref object of ReplayPayloadRef
    bag*: TraceFetchHeaders

  ReplaySyncHeaders* = ref object of ReplayPayloadRef
    bag*: TraceSyncHeaders


  ReplayFetchBodies* = ref object of ReplayPayloadRef
    bag*: TraceFetchBodies

  ReplaySyncBodies* = ref object of ReplayPayloadRef
    bag*: TraceSyncBodies


  ReplayImportBlock* = ref object of ReplayPayloadRef
    bag*: TraceImportBlock

  ReplaySyncBlock* = ref object of ReplayPayloadRef
    bag*: TraceSyncBlock

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

template replayLabel*(w: untyped): string =
  ## Static getter, retrieve replay type label
  TraceTypeLabel[(typeof w.bag).toTraceRecType]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
