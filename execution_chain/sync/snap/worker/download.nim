# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronicles, chronos],
  ./[account, helpers, header, mpt, state_db, worker_desc]

# ------------------------------------------------------------------------------
# Public function(s)
# ------------------------------------------------------------------------------

template download*(buddy: SnapPeerRef, info: static[string]) =
  ## Async/template
  ##
  ## Fetch and stash account, storage, and code ranges for available state
  ## roots, the order of which is determined by the following criteria with
  ## decreaning priority
  ##
  ## * the state that has already the most accounts downloaded
  ## * the pivot state for this `peer`
  ## * other states with decreasing block number (i.e. most recent first)
  ##   + not older than the first two states (if any),
  ##   + and no more than `nWorkingStateRoots`
  ##
  block body:
    # Make sure that this sync peer is not banned from processing, already.
    if nProcAccountErrThreshold < buddy.nErrors.apply.acc:
      buddy.ctrl.zombie = true
      break body                                    # return err()

    let
      ctx = buddy.ctx
      sdb = ctx.pool.stateDB
      peer {.inject,used.} = $buddy.peer            # logging only

    # Add new state records if pivots and free slots are available
    if buddy.only.pivotRoot.isNone():
      let ethPeer = buddy.getEthPeer()              # get `ethXX` peer if avail
      if not ethPeer.isNil:
        trace info & ": assigning best/latest pivotHash", peer,
          hash=ethPeer.only.pivotHash.short
        buddy.headerStateRegister(BlockHash(ethPeer.only.pivotHash)).isErrOr:
          buddy.only.pivotRoot = Opt.some(value)

    if sdb.len == 0:
      trace info & ": no state records", peer
      break body

    # Fetch for state DB items, start with pivot root
    var theseFirst: seq[StateRoot]
    let maxDone = sdb.getMaxDone()
    if maxDone.isSome():                            # the one with mose done yet
      theseFirst.add StateRoot(maxDone.unsafeGet().header.stateRoot)
    if buddy.only.pivotRoot.isSome():               # best supported by peer
      theseFirst.add buddy.only.pivotRoot.unsafeGet()

    # Run `download()` for available states, the order of which is
    # determined by the following criteria with deacening priority
    #
    # * the state that has already the most accounts downloaded
    # * the pivot state for this `peer`
    # * other states with decreasing block number (i.e. most recent first)
    #   + not older than the first two states (if any),
    #   + and no more than `nWorkingStateRoots`
    #
    var nStates {.inject.} = 0
    block downloadLoop:

      for state in sdb.items(startWith=theseFirst, truncate=true):
        var didSomething = false
        while true:
          if buddy.ctrl.stopped:                    # stop, nothing more to do
            break downloadLoop
          let acc = buddy.accountDownload(state, info).valueOr:
            break                                   # done this state, try next
          let used {.used.} = acc                   # FIXME: will go away 
          didSomething = true                       # continue with this one

        if didSomething:
          ctx.daemon = true                         # unless enabled, already
          nStates.inc
          if nWorkingStateRootsMax <= nStates:
            break downloadLoop                      # all done for now

    trace info & ": download states", peer, syncState=buddy.syncState,
      nStates

  discard # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
