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
  ./[account, code, helpers, header, mpt, state_db, storage, worker_desc]

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
          hash=ethPeer.only.pivotHash.short, nSyncPeers=ctx.nSyncPeers()
        buddy.headerStateRegister(BlockHash(ethPeer.only.pivotHash)).isErrOr:
          buddy.only.pivotRoot = Opt.some(value)

    if sdb.len == 0:
      trace info & ": no state records", peer
      break body

    # Fetch for state DB items, start with pivot root
    var theseFirst: seq[StateRoot]
    sdb.pivot.isErrOr:                              # the one with most done yet
      theseFirst.add StateRoot(value.header.stateRoot)
    buddy.only.pivotRoot.isErrOr:                   # best supported by peer
      theseFirst.add value

    # Run `download()` for available states, the order of which is
    # determined by the following criteria with deacening priority
    #
    # * the state that has already the most accounts downloaded
    # * the pivot state for this `peer`
    # * other states with decreasing block number (i.e. most recent first)
    #   + not older than the first two states (if any),
    #   + and no more than `nWorkingStateRoots`
    #
    var
      nStatesOk {.inject.} = 0
      nStatesIdle {.inject.} = 0
    block downloadLoop:
      for state in sdb.items(startWith=theseFirst, truncate=true):
        var didSomething = false
        while true:
          if buddy.ctrl.stopped:                    # stop, nothing more to do
            break downloadLoop
          let acc = buddy.accountDownload(state, info).valueOr:
            break                                   # done this state, try next
          buddy.storageDownload(state, acc, info)   # fetch storage slotes
          buddy.codeDownload(state, acc, info)      # fetch byte codes
          didSomething = true                       # continue with this one

        if didSomething:
          ctx.daemon = true                         # unless enabled, already
          nStatesOk.inc
          if nWorkingStateRootsMax <= nStatesOk:
            break downloadLoop                      # all done for now
        else:
          nStatesIdle.inc

    # Abandon peer if useless
    if buddy.ctrl.running and
       0 < ctx.nSyncPeers() and
       nStatesOk == 0 and 0 < nStatesIdle:
      buddy.ctrl.stopped = true

    trace info & ": downloaded states", peer, syncState=buddy.syncState,
      nStatesOk, nStatesIdle, nSyncPeers=ctx.nSyncPeers(),
      state=($buddy.syncState)

  discard                                           # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
