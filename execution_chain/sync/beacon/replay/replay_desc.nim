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

  ReplayBeginHeaders* = ref object of ReplayPayloadRef
    data*: TraceBeginHeaders

  ReplayGetBlockHeaders* = ref object of ReplayPayloadRef
    data*: TraceGetBlockHeaders


  ReplayBeginBlocks* = ref object of ReplayPayloadRef
    data*: TraceBeginBlocks

  ReplayGetBlockBodies* = ref object of ReplayPayloadRef
    data*: TraceGetBlockBodies

  ReplayImportBlock* = ref object of ReplayPayloadRef
    data*: TraceImportBlock

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
