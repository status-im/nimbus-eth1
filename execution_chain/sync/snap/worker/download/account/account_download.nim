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
  ../../[helpers, mpt, state_db, worker_desc],
  ./account_fetch

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template accountDownload*(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    info: static[string];                           # Log message prefix
      ): Opt[seq[SnapAccount]] =
  ## Async/template
  ##
  ## On success, the template returns a list of accounts for storage and
  ## code processing.
  ##
  var bodyRc = Opt[seq[SnapAccount]].err()
  block body:
    let
      ctx = buddy.ctx
      sdb = ctx.pool.stateDB
      adb = ctx.pool.mptAsm

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = state.rootStr          # logging only

      ivReq = sdb.fetchAccountRange(state).valueOr:
        trace info & ": no more unpocessed", peer, root
        break body                                  # return err()

      iv {.inject,used.} = ivReq.flStr              # logging only

    trace info & ": requesting account range", peer, root, iv

    let
      data = buddy.fetchAccounts(state.stateRoot, ivReq).valueOr:
        sdb.rollbackAccountRange(state, ivReq)      # registry roll back
        if error == ENoDataAvailable:
          state.downScore()
        trace info & ": account download failed", peer, root, iv,
          `error`=error
        break body                                  # return err()

      limit = if data.accounts.len == 0: high(ItemKey)
              else: data.accounts[^1].accHash.to(ItemKey)

      nAccounts {.inject,used.} = data.accounts.len # logging only
      nProof {.inject,used.} = data.proof.len       # logging only

    # Stash accounts data packet to be processed later
    adb.putRawAccounts(
      state.stateRoot, ivReq.minPt, limit, data.accounts, data.proof,
      buddy.peerID).isOkOr:
        sdb.rollbackAccountRange(state, ivReq)      # registry roll back
        debug info & ": caching accounts failed", peer, root, iv,
          nAccounts, nProof
        break body                                  # return err()

    state.upScore()                                 # got some data
    sdb.commitAccountRange(state, ivReq, limit)     # update registry
    bodyRc = typeof(bodyRc).ok(data.accounts)       # return code

    debug info & ": accounts downloaded and cached", peer, root, iv,
      nAccounts, nProof

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
