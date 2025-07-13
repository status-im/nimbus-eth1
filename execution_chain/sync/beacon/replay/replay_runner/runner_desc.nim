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


  ReplayCtxRef* = ref object of RootRef
    ## Context data base record to be held on the `stage[]` stack
    recType*: TraceRecType             ## Sub-type selector

  # --------- stage level 0 ---------

  ReplayFrameRef* = ref object of ReplayCtxRef
    ## Begin/end frame context. This frame record on `stage[0]` also serves
    ## as a sync device for sub-tasks, see functions
    ## `dispatch_helpers.provideSessionData()` or 
    ## `dispatch_helpers.provideSessionData()` for details.
    ##
    frameID*: uint64                   ## Active begin/end frame
    done*: bool                        ## Finished with frame task
    subSync*: TraceRecType             ## Data request sync from sub-task

  ReplayDaemonFrameRef* = ref object of ReplayFrameRef
    ## Daemon instruction context

  ReplayPeerFrameRef* = ref object of ReplayFrameRef
    ## Peer instruction context

  # --------- stage level 1 ---------

  ReplaySubCtxRef* = ref object of ReplayCtxRef
    ## Sub task context                ## Identifies captured environment

  ReplayHdrBeginSubCtxRef* = ref object of ReplaySubCtxRef
    ## Headers begin sync point data
    instr*: TraceBeginHeaders           ## Full context/environment

  ReplayHeadersSubCtxRef* = ref object of ReplaySubCtxRef
    ## Staged headers fetch data
    instr*: TraceGetBlockHeaders        ## Full context/environment

  ReplayBlkBeginSubCtxRef* = ref object of ReplaySubCtxRef
    ## Blocks begin sync point data
    instr*: TraceBeginBlocks            ## Full context/environment

  ReplayBodiesSubCtxRef* = ref object of ReplaySubCtxRef
    ## Bodies fetch task indicator
    instr*: TraceGetBlockBodies         ## Full context/environment

  ReplayImportSubCtxRef* = ref object of ReplaySubCtxRef
    ## Bodies fetch task indicator
    instr*: TraceImportBlock          ## Full context/environment

  # ---------

  ReplayDaemonRef* = ref object
    ## Daemeon job frame
    run*: ReplayRunnerRef              ## Back-reference for convenience
    stage*: seq[ReplayCtxRef]          ## Stack for Begin/end frames

  ReplayBuddyRef* = ref object of BeaconBuddyRef
    ## Replacement of `BeaconBuddyRef` in `runPeer()` and `runPool()`
    isNew*: bool                       ## Set in `getOrNewPeer()` when created
    run*: ReplayRunnerRef              ## Back-reference for convenience
    stage*: seq[ReplayCtxRef]          ## Stack for Begin/end frames

  ReplayEthState* = object
    ## Some feake settings to pretent eth/xx compatibility
    capa*: Dispatcher                  ## Cabability `eth68`, `eth69`, etc.
    prots*: seq[RootRef]               ## `capa` init flags, protocol states

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

# End
