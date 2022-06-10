# Nimbus - Fetch account and storage states from peers efficiently
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
  chronos,
  nimcrypto/keccak,
  stint,
  eth/[common/eth_types, p2p],
  ../../../utils/interval_set,
  "../.."/[protocol, types],
  ../path_desc,
  ./fetch/fetch_snap,
  "."/[ticker, worker_desc]

{.push raises: [Defect].}

logScope:
  topics = "snap fetch"

const
  accRangeMaxLen = (high(LeafItem) - low(LeafItem)) div 1000

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc withMaxLen(iv: LeafRange): LeafRange =
  ## Reduce accounts interval to maximal size
  if 0 < iv.len and iv.len < accRangeMaxLen:
    iv
  else:
    LeafRange.new(iv.minPt, iv.minPt + (accRangeMaxLen - 1).u256)

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc fetchSetup*(ns: Worker) =
  ## Global set up
  ns.tickerSetup()
  ns.accRange = LeafRangeSet.init()
  # Pre-fill with largest interval
  discard ns.accRange.merge(low(LeafItem),high(LeafItem))

proc fetchRelease*(ns: Worker) =
  ## Global clean up
  ns.tickerRelease()

proc fetchStart*(sp: WorkerBuddy) =
  ## Initialise `WorkerBuddy` to support `ReplyData.new()` calls.
  trace "Supported fetch modes", peer=sp,
    ctrlState=sp.ctrl.state, snapAvail=sp.peer.supports(protocol.snap)

proc fetchStop*(sp: WorkerBuddy) =
  ## Clean up for this peer
  discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetch*(sp: WorkerBuddy) {.async.} =

  if not sp.peer.supports(protocol.snap):
    trace "Peer does not support snap", peer=sp
    return

  var stateRoot = sp.ctrl.stateRoot.get
  trace "Syncing from stateRoot", peer=sp, stateRoot

  sp.tickerStartPeer()

  while not sp.ctrl.stopped:

    if sp.ns.accRange.chunks == 0:
      trace "Nothing more to sync from this peer", peer=sp
      while sp.ns.accRange.chunks == 0:
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.

    if sp.ctrl.stateRoot.isNone:
      trace "No current state root for this peer", peer=sp
      while not sp.ctrl.stopped and
            0 < sp.ns.accRange.chunks and
            sp.ctrl.stateRoot.isNone:
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    if stateRoot != sp.ctrl.stateRoot.get:
      trace "Syncing from new stateRoot", peer=sp, stateRoot
      stateRoot = sp.ctrl.stateRoot.get
      sp.ctrl.stopped = false

    if sp.ctrl.stopRequest:
      trace "Pausing sync until we get a new state root", peer=sp
      while not sp.ctrl.stopped and
            0 < sp.ns.accRange.chunks and
            sp.ctrl.stateRoot.isSome and
            stateRoot == sp.ctrl.stateRoot.get:
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    if sp.ctrl.stopped:
      continue

    # Get a new range of accounts to visit
    let accRangeRc = sp.ns.accRange.ge()
    if accRangeRc.isOk:
      let accRange = accRangeRc.value.withMaxLen
      discard sp.ns.accRange.reduce(accRange) # reduce from pool

      let rc = await sp.fetchSnap(stateRoot, accRange)
      if rc.isOk:
        discard sp.ns.accRange.merge(rc.value) # return back to pool

  # while end

  trace "No more sync available from this peer", peer=sp
  sp.tickerStopPeer()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
