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
  std/sequtils,
  pkg/[chronicles, chronos],
  ../../[helpers, mpt, state_db, worker_desc],
  ./code_fetch

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc register(state: StateDataRef, acc: seq[(ItemKey,CodeHash)]) =
  for (key,val) in acc:
    state.register(key,val)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template downloadImpl(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    accounts: seq[(ItemKey,CodeHash)];              # Acoounts with contracts
    info: static[string];                           # Log message prefix
      ): bool =
  ## Async/template
  ##
  ## The template will return `true` if there were some data that could be
  ## downloaded and processed.
  ##
  var bodyRc = false
  block body:
    let
      ctx = buddy.ctx
      adb = ctx.pool.mptAsm
      sRoot = state.stateRoot
      peerID = buddy.peerID

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = state.rootStr          # logging only

    # Fetch storage slots from argument list `accounts`
    var start {.inject.} = 0
    while start < accounts.len:
      let
        accLeft = if start == 0: accounts else: accounts[start .. ^1]
        codeHashes = accLeft.mapIt(it[1])

      # Fetch from network
      let data = buddy.fetchCodes(sRoot, codeHashes).valueOr:
        state.register accLeft                      # stash data and return
        trace info & ": fetching codes failed", peer, root,
          start, nAccLeft=accLeft.len
        break body                                  # error => return

      # Store byte codes on database
      adb.putRawAyteCode(
        sRoot, accLeft[0][0], accLeft[^1][0],
        codeHashes.zip data.codes, peerID).isOkOr:
          state.register(accLeft)                   # stash data and return
          trace info & ": storing codes failed", peer, root,
            start, nAccLeft=accLeft.len
          break body                                # error => return

      start += data.codes.len
      bodyRc = true                                 # did something

      # End `while`

  bodyRc

template downloadFromQueue(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    info: static[string];                           # Log message prefix
      ): bool =
  ## Async/template
  ##
  ## Process stashed unprocessed byte codes from the state DB.
  ##
  ## The template will return `true` if there were some data that could be
  ## downloaded and processed.
  ##
  var bodyRc = false
  block body:
    let
      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = state.rootStr          # logging only
    var
      accQueue: seq[(ItemKey,CodeHash)]

    for w in state.stoItems:
      accQueue.add (w.key, w.data.code)
      state.delCode w.key

    if 0 < accQueue.len:
      trace info & ": processing from codes queue", peer, root,
        nAccQueue=accQueue.len
      if buddy.downloadImpl(state, accQueue, info):
        bodyRc = true

  bodyRc

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template codeDownload*(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    accounts: seq[SnapAccount];                     # Acoounts with sub-tries
    info: static[string];                           # Log message prefix
      ) =
  ## Async/template
  ##
  block body:
    let acc = accounts
       .filterIt(not it.accBody.codeHash.isEmpty)
       .mapIt( (it.accHash.to(ItemKey),
                it.accBody.codeHash.to(Hash32).to(CodeHash)) )

    if buddy.ctrl.stopped:
      state.register acc                            # stash data and return
      break body                                    # all done

    discard buddy.downloadImpl(state, acc, info)

    while not buddy.ctrl.stopped and
          0 < state.len and
          buddy.downloadFromQueue(state, info):
      continue

  discard                                           # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
