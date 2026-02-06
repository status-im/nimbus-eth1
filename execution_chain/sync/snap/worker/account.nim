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
  account/account_fetch,
  ./[helpers, header, state_db, worker_desc]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template updateTarget(
    buddy: SnapPeerRef;
    info: static[string];
      ) =
  ## Async/template
  ##
  block body:
    # Check whether explicit target setup is configured
    if buddy.ctx.pool.target.isSome():
      let
        peer {.inject,used.} = $buddy.peer          # logging only
        ctx = buddy.ctx

      # Single target block hash
      if ctx.pool.target.value.blockHash != BlockHash(zeroHash32):
        let rc = buddy.headerStateRegister(ctx.pool.target.value.blockHash)
        if rc.isErr and rc.error:                       # real error
          trace info & ": failed fetching pivot hash", peer,
            hash=ctx.pool.target.value.blockHash.toStr
        elif 0 < ctx.pool.target.value.updateFile.len:
          var target = ctx.pool.target.value
          target.blockHash = BlockHash(zeroHash32)
          ctx.pool.target = Opt.some(target)
        else:
          ctx.pool.target = Opt.none(SnapTarget)    # No more target entries
          break body                                # noting more to do here

      # Check whether a file target setup is configured
      if 0 < ctx.pool.target.value.updateFile.len:
        trace info & ": target update from file", peer,
          file=ctx.pool.target.value.updateFile
        discard buddy.headerStateLoad(ctx.pool.target.value.updateFile, info)
        trace info & ": target update from file.. done", peer

  discard # visual alignment


template download(
    buddy: SnapPeerRef;
    state: StateDataRef;
    info: static[string];
      ) =
  ## Async/template
  ##
  block body:
    let
      ctx = buddy.ctx
      sdb = ctx.pool.stateDB

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = state.rootStr          # logging only

      iv = state.unproc.fetchLeast(unprocAccountsRangeMax).valueOr:
        trace info & ": no more unpocessed", peer, root, stateDB=sdb.toStr
        break body

      accData = buddy.fetchAccounts(state.root, iv).valueOr:
        state.unproc.commit(iv, iv) # registry roll back
        state.downScore()
        trace info & ": account download failed", peer, root,
          iv=iv.to(float).toStr, stateDB=sdb.toStr
        break body

    # Accept, update registry
    if 0 < accData.accounts.len:
      let accTop = accData.accounts[^1].accHash.to(ItemKey)
      state.unproc.commit(iv, accTop + 1, iv.maxPt)
      state.unproc.overCommit(iv.maxPt + 1, accTop)
      state.upScore()
    else:
      state.downScore()

    debug info & ": accounts downloaded", peer, root, iv=iv.to(float).toStr,
      nAccounts=accData.accounts.len, nProof=accData.proof.len,
      stateDB=sdb.toStr

    discard                                         # visual alignment

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template accountRangeImport*(buddy: SnapPeerRef; info: static[string]) =
  ## Async/template
  ##
  ## Fetch and stash account ranges -- TBD
  ##
  block body:
    let
      ctx = buddy.ctx
      sdb = ctx.pool.stateDB
      peer {.inject,used.} = $buddy.peer            # logging only

    # Update state db, add new state records if pivots are available
    if buddy.only.pivotRoot.isNone():
      let ethPeer = buddy.getEthPeer()              # get `ethXX` peer if avail
      if not ethPeer.isNil:
        trace info & ": processing best/latest pivotHash", peer,
          hash=ethPeer.only.pivotHash.short
        buddy.headerStateRegister(BlockHash(ethPeer.only.pivotHash)).isErrOr:
          buddy.only.pivotRoot = Opt.some(value)

    # Check for maual target settings
    buddy.updateTarget info

    if ctx.pool.stateDB.len == 0:
      trace info & ": no state records", peer, stateDB=sdb.toStr
      break body

    # Fetch for state DB items, start with pivot root
    for state in sdb.items(startWith=buddy.only.pivotRoot, truncate=true):
      if buddy.ctrl.stopped:
        break
      trace info & ": download state", peer, root=state.rootStr,
        stateDB=sdb.toStr
      buddy.download(state, info)

  discard # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
