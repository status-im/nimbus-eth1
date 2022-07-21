# Nimbus - New sync approach - A fusion of snap, trie, beam and other methods
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  eth/[common/eth_types, p2p]

{.push raises: [Defect].}

type
  BuddyRunState = enum
    ## Combined state of two boolean values (`stopped`,`stopThisState`) as used
    ## in the original source set up (should be double checked and simplified.)
    Running = 0             ## running, default state
    Stopped                 ## stopped or about stopping
    ZombieStop              ## abandon/ignore (LRU tab overflow, odd packets)
    ZombieRun               ## extra zombie state to potentially recover from

  BuddyCtrl* = object
    ## Control and state settings
    runState: BuddyRunState ## Access with getters
    multiPeer: bool         ## Triggers `runSingle()` mode unless `true`

  BuddyDataRef* = ref object of RootObj
    ## Stub object, to be inherited in file `worker.nim`

  BuddyRef* = ref object
    ## Non-inheritable peer state tracking descriptor.
    ctx*: CtxRef            ## Shared data back reference
    peer*: Peer             ## Reference to eth p2pProtocol entry
    ctrl*: BuddyCtrl        ## Control and state settings
    data*: BuddyDataRef     ## Opaque object reference for sub-module

  # -----

  CtxDataRef* = ref object of RootObj
    ## Stub object, to be inherited in file `worker.nim`

  CtxRef* = ref object of RootObj
    ## Shared state among all syncing peer workers (aka buddies.) This object
    ## Will be amended/inherited main module which controls the peer workers.
    buddiesMax*: int        ## Max number of buddies (for LRU cache, read only)
    chain*: AbstractChainDB ## Block chain database (read only reference)
    poolMode*: bool         ## Activate `runPool()` workers if set `true`
    data*: CtxDataRef       ## Opaque object reference for sub-module

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc `$`*(buddy: BuddyRef): string =
  $buddy.peer & "$" & $buddy.ctrl.runState

# ------------------------------------------------------------------------------
# Public getters, `BuddyRunState` execution control functions
# ------------------------------------------------------------------------------

proc multiOk*(ctrl: BuddyCtrl): bool =
  ## Getter
  ctrl.multiPeer

proc state*(ctrl: BuddyCtrl): BuddyRunState =
  ## Getter (logging only, details of `BuddyCtrl` are private)
  ctrl.runState

proc running*(ctrl: BuddyCtrl): bool =
  ## Getter, if `true` if `ctrl.state()` is `Running`
  ctrl.runState == Running

proc stopped*(ctrl: BuddyCtrl): bool =
  ## Getter, if `true`, if `ctrl.state()` is not `Running`
  ctrl.runState in {Stopped, ZombieStop, ZombieRun}

proc zombie*(ctrl: BuddyCtrl): bool =
  ## Getter, `true` if `ctrl.state()` is `Zombie` (i.e. not `running()` and
  ## not `stopped()`)
  ctrl.runState in {ZombieStop, ZombieRun}

# ------------------------------------------------------------------------------
# Public setters, `BuddyRunState` execution control functions
# ------------------------------------------------------------------------------

proc `multiOk=`*(ctrl: var BuddyCtrl; val: bool) =
  ## Setter
  ctrl.multiPeer = val

proc `zombie=`*(ctrl: var BuddyCtrl; value: bool) =
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

proc `stopped=`*(ctrl: var BuddyCtrl; value: bool) =
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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
