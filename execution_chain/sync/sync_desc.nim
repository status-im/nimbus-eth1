# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Worker peers scheduler template
## ===============================
##
## Public descriptors

{.push raises: [].}

import
  std/hashes,
  ../networking/p2p

type
  GetSyncPeerFn*[S,W] = proc(peerID: Hash): SyncPeerRef[S,W] {.gcsafe, raises: [].}
    ## Get other active syncer peers (aka buddy) by its ID. This peer will not
    ## be returned unless the `runStart()` directive for this particular peer
    ## (with `peerID` as ID) has returned `true`. The returned peer `buddy`
    ## will not be marked for termination, i.e. `buddy.ctrl.running` evaluates
    ## `true`.

  GetSyncPeersFn*[S,W] = proc(): seq[SyncPeerRef[S,W]] {.gcsafe, raises: [].}
    ## Get the list of descriptors for all active syncer peers (aka buddies).
    ## The peers returned are all the peers where the `runStart()` directive
    ## has returned `true` (see `GetPeerFn`.)

  NSyncPeersFn*[S,W] = proc(): int {.gcsafe, raises: [].}
    ## Efficient version of `getSyncPeersFn().len`. This number returned
    ## here might be slightly larger than `dsc.getSyncPeersFn().len` because
    ## peers marked `stopped` (i.e. to be terminated) are also included
    ## in the count.

  SyncPeerRunState* = enum
    Running = 0             ## Running, default state
    Stopped                 ## Stopped or about stopping
    ZombieStop              ## Abandon/ignore (wait for pushed out of LRU table)
    ZombieRun               ## Extra zombie state to potentially recover from

  SyncPeerCtrl* = object
    ## Control and state settings
    runState: SyncPeerRunState  ## Access with getters

  SyncPeerRef*[S,W] = ref object of RootRef
    ## Worker peer state descriptor.
    ctx*: CtxRef[S,W]           ## Shared data descriptor back reference
    peer*: Peer                 ## Reference to eth `p2p` protocol entry
    peerID*: Hash               ## Hash of peer node
    ctrl*: SyncPeerCtrl         ## Control and state settings
    only*: W                    ## Worker peer specific data

  CtxRef*[S,W] = ref object
    ## Shared state among all syncing peer workers (aka buddies.)
    getSyncPeer*: GetSyncPeerFn[S,W]
    getSyncPeers*: GetSyncPeersFn[S,W]
    nSyncPeers*: NSyncPeersFn[S,W]
    node*: EthereumNode         ## Own network identity
    noisyLog*: bool             ## Hold back `trace` and `debug` msgs if `false`
    poolMode*: bool             ## Activate `runPool()` workers if set `true`
    daemon*: bool               ## Enable global background job
    pool*: S                    ## Shared context for all worker peers

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc `$`*[S,W](worker: SyncPeerRef[S,W]): string =
  $worker.peer & "$" & $worker.ctrl.runState

# ------------------------------------------------------------------------------
# Public getters, `SyncPeerRunState` execution control functions
# ------------------------------------------------------------------------------

proc state*(ctrl: SyncPeerCtrl): SyncPeerRunState =
  ## Getter (logging only, details of `SyncPeerCtrl` are private)
  ctrl.runState

proc running*(ctrl: SyncPeerCtrl): bool =
  ## Getter, if `true` if `ctrl.state()` is `Running`
  ctrl.runState == Running

proc stopped*(ctrl: SyncPeerCtrl): bool =
  ## Getter, if `true`, if `ctrl.state()` is not `Running`
  ctrl.runState != Running

proc zombie*(ctrl: SyncPeerCtrl): bool =
  ## Getter, `true` if `ctrl.state()` is `Zombie` (i.e. not `running()` and
  ## not `stopped()`)
  ctrl.runState in {ZombieStop, ZombieRun}

# ------------------------------------------------------------------------------
# Public setters, `SyncPeerRunState` execution control functions
# ------------------------------------------------------------------------------

proc `zombie=`*(ctrl: var SyncPeerCtrl; value: bool) =
  ## Setter
  if value:
    case ctrl.runState:
    of Running:
      ctrl.runState = ZombieRun
    of Stopped:
      ctrl.runState = ZombieStop
    else:
      discard
  else:
    case ctrl.runState:
    of ZombieRun:
      ctrl.runState = Running
    of ZombieStop:
      ctrl.runState = Stopped
    else:
      discard

proc `stopped=`*(ctrl: var SyncPeerCtrl; value: bool) =
  ## Setter
  if value:
    case ctrl.runState:
    of Running:
      ctrl.runState = Stopped
    else:
      discard
  else:
    case ctrl.runState:
    of Stopped:
      ctrl.runState = Running
    else:
      discard

proc `forceRun=`*(ctrl: var SyncPeerCtrl; value: bool) =
  ## Setter, gets out of `Zombie` jail/locked state with `true` argument.
  if value:
    ctrl.runState = Running
  else:
    ctrl.stopped = true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
