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
## TODO
## * Job(ID) -> stage(ID)

{.push raises:[].}

import
  std/tables,
  ../../../../networking/p2p,
  ../../../wire_protocol,
  ../../trace/trace_desc,
  ../../worker_desc

type
  ReplayStopRunnnerFn* = proc(): bool {.gcsafe, raises: [].}
    ## Loop control directive for runner/dispatcher

  ReplayWaitError* = tuple
    ## Capture exception or error context for waiting/polling instance
    excp: BeaconErrorType
    name: string
    msg: string

  # --------- data messages ---------

  ReplayMsgRef* = ref object of RootRef
    ## Sub task context                ## Identifies captured environment
    recType*: TraceRecType             ## Sub-type selector

  ReplayFetchHeadersMsgRef* = ref object of ReplayMsgRef
    ## Staged headers fetch data
    instr*: TraceFetchHeaders          ## Full context/environment

  ReplaySyncHeadersMsgRef* = ref object of ReplayMsgRef
    ## Staged headers fetch data
    instr*: TraceSyncHeaders           ## Full context/environment

  ReplayFetchBodiesMsgRef* = ref object of ReplayMsgRef
    ## Bodies fetch task indicator
    instr*: TraceFetchBodies           ## Full context/environment

  ReplaySyncBodiesMsgRef* = ref object of ReplayMsgRef
    ## Bodies fetch task indicator
    instr*: TraceSyncBodies            ## Full context/environment

  ReplayImportBlockMsgRef* = ref object of ReplayMsgRef
    ## Bodies fetch task indicator
    instr*: TraceImportBlock           ## Full context/environment

  ReplaySyncBlockMsgRef* = ref object of ReplayMsgRef
    ## Bodies fetch task indicator
    instr*: TraceSyncBlock             ## Full context/environment

  # ---------

  ReplayDaemonRef* = ref object
    ## Daemeon job frame
    run*: ReplayRunnerRef              ## Back-reference for convenience
    frameID*: uint64                   ## Begin/end frame
    message*: ReplayMsgRef             ## Data message channel

  ReplayBuddyRef* = ref object of BeaconBuddyRef
    ## Replacement of `BeaconBuddyRef` in `runPeer()` and `runPool()`
    isNew*: bool                       ## Set in `getOrNewPeer()` when created
    run*: ReplayRunnerRef              ## Back-reference for convenience
    frameID*: uint64                   ## Begin/end frame
    message*: ReplayMsgRef             ## Data message channel

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

    # Instruction handling
    instrNumber*: uint                 ## Instruction counter

    # Debugging
    noisy*: bool                       ## Activates extra logging noise
    startNoisy*: uint                  ## Cycle threshold for noisy logging
    fakeImport*: bool                  ## No database import if `true`

# End
