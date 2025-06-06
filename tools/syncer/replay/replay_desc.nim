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
  ../trace/trace_desc,
  ./replay_reader/reader_desc

export
  reader_desc,
  trace_desc

const
  ReplaySetupID* = 2                    ## Phase 1 layout ID, prepare
  ReplayRunnerID* = 20                  ## Phase 2 layout ID, full execution

type
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
# End
# ------------------------------------------------------------------------------
