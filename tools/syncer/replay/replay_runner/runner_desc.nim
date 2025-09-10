# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay runner
##

{.push raises:[].}

import
  std/tables,
  pkg/chronos,
  ../../../../execution_chain/networking/p2p,
  ../../../../execution_chain/sync/wire_protocol,
  ../../../../execution_chain/sync/beacon/worker/worker_desc,
  ../../trace/trace_desc

const
  replayWaitForCompletion* = chronos.nanoseconds(100)
    ## Wait for other pseudo/async thread to have completed something

  replayFailTimeout* = chronos.seconds(50)
    ## Bail out after waiting this long for an event to happen. This
    ## timeout should cover the maximum time needed to import a block.

  replayFailTmoMinLog* = chronos.milliseconds(1)
    ## Log maximum elapsed time when it exceeds this threshold.

  replayWaitMuted* = chronos.milliseconds(200)
    ## Some handlers are muted, but keep them in a waiting loop so
    ## the system can terminate

type
  ReplayWaitError* = tuple
    ## Capture exception or error context for waiting/polling instance
    excp: BeaconErrorType
    name: string
    msg: string

  # --------- internal data message types ---------

  ReplayMsgRef* = ref object of RootRef
    ## Sub task context                ## Identifies captured environment
    recType*: TraceRecType             ## Sub-type selector

  ReplayFetchHeadersMsgRef* = ref object of ReplayMsgRef
    ## Headers fetch data message
    instr*: TraceFetchHeaders          ## Full context/environment

  ReplaySyncHeadersMsgRef* = ref object of ReplayMsgRef
    ## Headers fetch sync message
    instr*: TraceSyncHeaders           ## Full context/environment

  ReplayFetchBodiesMsgRef* = ref object of ReplayMsgRef
    ## Bodies fetch data message
    instr*: TraceFetchBodies           ## Full context/environment

  ReplaySyncBodiesMsgRef* = ref object of ReplayMsgRef
    ## Bodies fetch sync message
    instr*: TraceSyncBodies            ## Full context/environment

  ReplayImportBlockMsgRef* = ref object of ReplayMsgRef
    ## Block import data message
    instr*: TraceImportBlock           ## Full context/environment

  ReplaySyncBlockMsgRef* = ref object of ReplayMsgRef
    ## Block import sync message
    instr*: TraceSyncBlock             ## Full context/environment

  # --------- internal context types ---------

  ReplayBuddyRef* = ref object of BeaconBuddyRef
    ## Replacement of `BeaconBuddyRef` in `runPeer()` and `runPool()`
    isNew*: bool                       ## Set in `getOrNewPeer()` when created
    run*: ReplayRunnerRef              ## Back-reference for convenience
    frameID*: uint64                   ## Begin/end frame
    message*: ReplayMsgRef             ## Data message channel

  ReplayDaemonRef* = ref object
    ## Daemeon job frame (similar to `ReplayBuddyRef`)
    run*: ReplayRunnerRef              ## Back-reference for convenience
    frameID*: uint64                   ## Begin/end frame
    message*: ReplayMsgRef             ## Data message channel

  # ---------

  ReplayEthState* = object
    ## Some feake settings to pretent eth/xx compatibility
    capa*: Dispatcher                  ## Cabability `eth68`, `eth69`, etc.
    prots*: array[MAX_PROTOCOLS,RootRef] ## `capa` init flags, protocol states

  ReplayRunnerRef* = ref object
    # Global state
    ctx*: BeaconCtxRef                 ## Beacon syncer descriptor
    worker*: BeaconHandlersRef         ## Refers to original handlers table
    ethState*: ReplayEthState          ## For ethxx compatibility
    stopRunner*: bool                  ## Shut down request
    nSessions*: int                    ## Numer of sessions left

    # Local state
    daemon*: ReplayDaemonRef           ## Currently active daemon, or `nil`
    peers*: Table[Hash,ReplayBuddyRef] ## Begin/End for base frames
    nPeers*: uint                      ## Track active peer instances
    failTmoMax*: chronos.Duration      ## Keep track of largest timeout

    # Instruction handling
    instrNumber*: uint                 ## Instruction counter
    fakeImport*: bool                  ## No database import if `true`

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

template toReplayMsgType*(trc: type): untyped =
  ## Derive replay record type from trace capture record type
  when trc is TraceFetchHeaders:
    ReplayFetchHeadersMsgRef
  elif trc is TraceSyncHeaders:
    ReplaySyncHeadersMsgRef
  elif trc is TraceFetchBodies:
    ReplayFetchBodiesMsgRef
  elif trc is TraceSyncBodies:
    ReplaySyncBodiesMsgRef
  elif trc is TraceImportBlock:
    ReplayImportBlockMsgRef
  elif trc is TraceSyncBlock:
    ReplaySyncBlockMsgRef
  else:
    {.error: "Unsupported trace record type".}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
