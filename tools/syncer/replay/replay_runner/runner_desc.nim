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
  ../../trace/trace_desc,
  ../replay_desc

export
  replay_desc

const
  replayWaitForCompletion* = chronos.nanoseconds(100)
    ## Wait for other pseudo/async thread to have completed something

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

  # --------- internal context types ---------

  ReplayBuddyRef* = ref object of BeaconBuddyRef
    ## Replacement of `BeaconBuddyRef` in `runPeer()` and `runPool()`
    isNew*: bool                       ## Set in `getOrNewPeer()` when created
    run*: ReplayRunnerRef              ## Back-reference for convenience
    frameID*: Opt[uint]                ## Begin/end frame
    message*: ReplayPayloadRef         ## Data message channel

  ReplayDaemonRef* = ref object
    ## Daemeon job frame (similar to `ReplayBuddyRef`)
    run*: ReplayRunnerRef              ## Back-reference for convenience
    frameID*: Opt[uint]                ## Begin/end frame
    message*: ReplayPayloadRef         ## Data message channel

  # ---------

  ReplayEthState* = object
    ## Some feake settings to pretent eth/xx compatibility
    capa*: Dispatcher                  ## Cabability `eth68`, `eth69`, etc.
    prots*: array[MAX_PROTOCOLS,RootRef] ## `capa` init flags, protocol states

  ReplayRunnerRef* = ref object of ReplayRef
    # Global state
    ethState*: ReplayEthState          ## For ethxx compatibility
    stopRunner*: bool                  ## Shut down request
    nSessions*: int                    ## Numer of sessions left

    # Local state
    daemon*: ReplayDaemonRef           ## Currently active daemon, or `nil`
    peers*: Table[Hash,ReplayBuddyRef] ## Begin/End for base frames
    nSyncPeers*: int                   ## Track active peer instances
    failTmoMax*: chronos.Duration      ## Keep track of largest timeout

    # Instruction handling
    instrNumber*: uint                 ## Instruction counter

# ------------------------------------------------------------------------------
# Fake scheduler `getPeer()` and `getPeers()` for replay runner
# ------------------------------------------------------------------------------

proc replayGetSyncPeerFn*(run: ReplayRunnerRef): ReplayGetSyncPeerFn =
  result = proc(peerID: Hash): BeaconBuddyRef =
    run.peers.withValue(peerID,val):
      return val[]

proc replayNSyncPeersFn*(run: ReplayRunnerRef): ReplayNSyncPeersFn =
  result = proc(): int =
    run.nSyncPeers

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
