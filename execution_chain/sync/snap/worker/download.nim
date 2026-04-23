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
  ./download/[account, code, header, storage],
  ./[helpers, mpt, state_db, update, worker_desc]

export
  account, code, header, storage

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

    buddy.updateTarget info                         # manual target set up?
    buddy.updateFcuRoot info                        # FCU header => state

    let pivot = sdb.pivot.valueOr:
      trace info & ": no state records", peer
      break body                                    # return err()

    # Fetch for state DB items, start with pivot root
    var theseFirst: seq[StateRoot]
    theseFirst.add pivot.stateRoot
    buddy.only.finRoot.isErrOr:
      theseFirst.add value

    trace info & ": start downloading", peer,
      notAvailMax=buddy.only.notAvailMax,
      syncState=buddy.syncState, nSyncPeers=ctx.nSyncPeers()

    # Run `download()` for available states, the order of which is
    # determined by the following criteria with deacening priority
    #
    # * the pivot state for this `peer`
    # * the best state for this peer (sort of)
    # * other states with decreasing rank
    #
    var
      nStatesOk {.inject.} = 0
      nStatesIdle {.inject.} = 0
    block downloadLoop:
      for state in sdb.items(startWith=theseFirst,
                             ignoreLe=buddy.only.notAvailMax):
        var didSomething = false
        let state {.inject.} = state                # logging only, sub-template
        while true:
          if buddy.ctrl.stopped:                    # stop, nothing more to do
            break downloadLoop
          let
            rc = buddy.accountDownload(state, info)
            acc = if rc.isOk:
                    rc.value
                  elif rc.error == ECompleted:
                    @[]                             # try left over storage/code
                  else:
                    break                           # done this state, try next
          buddy.storageDownload(state, acc, info)   # fetch storage slots
          buddy.codeDownload(state, acc, info)      # fetch byte codes
          if not state.isOperable():                # proceed unless evicted
            break
          didSomething = true                       # continue with this one
          # End `while` single state download

        if didSomething:
          nStatesOk.inc
        else:
          nStatesIdle.inc
        # End `for` a list of state

    # Abandon peer if useless
    if buddy.ctrl.running and
       0 < ctx.nSyncPeers() and
       nStatesOk == 0 and 0 < nStatesIdle:
      buddy.ctrl.stopped = true

    trace info & ": downloaded states", peer,
      notAvailMax=buddy.only.notAvailMax, syncState=buddy.syncState,
      nStatesOk, nStatesIdle, nSyncPeers=ctx.nSyncPeers()

  discard                                           # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
