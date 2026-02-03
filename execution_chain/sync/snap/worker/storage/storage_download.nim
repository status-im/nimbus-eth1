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
  ../[helpers, mpt, state_db, worker_desc],
  ./storage_fetch

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc putStoAndProof(
    adb: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
    data: StorageRangesData;
    peerID: Hash;
      ): Result[void,string] =
  adb.putRawStoSlot(root, start, limit, data.slot, data.proof, peerID)

proc register(state: StateDataRef, acc: seq[(ItemKey,StoreRoot)]) =
  for (key,val) in acc:
    state.register(key,val)

proc register(state: StateDataRef, acc: (ItemKey,StoreRoot)) =
  state.register(acc[0], acc[1])

proc register(state: StateDataRef, acc: (ItemKey,StoreRoot), iv: ItemKeyRange) =
  state.register(acc[0], acc[1], iv)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template downloadImpl(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    accounts: seq[(ItemKey,StoreRoot)];             # Acoounts with sub-tries
    ivReq: ItemKeyRange;                            # Interval to fetch
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
      sRoot = state.root
      peerID = buddy.peerID

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = state.rootStr          # logging only

    # Fetch storage slots from argument list `accounts`
    var
      start {.inject.} = 0
      data: StorageRangesData
    while start < accounts.len:
      block:
        let
          accLeft = if start == 0: accounts else: accounts[start .. ^1]
          accHashes = accLeft.mapIt(it[0])

        # Fetch from network
        data = buddy.fetchStorage(sRoot, accHashes, ivReq).valueOr:
          state.register accLeft                    # stash data and return
          trace info & ": fetching slots failed", peer, root,
            start, nAccLeft=accLeft.len
          break body                                # error => return

        # Store complete sub-trees on database
        for n in 0 ..< data.slots.len:
          adb.putRawStoSlot(sRoot, data.slots[n], peerID).isOkOr:
            state.register(accounts[start .. ^1])   # stash data and return
            trace info & ": storing slots failed", peer, root, nStored=n,
              start, nAccLeft=(accounts.len - start)
            break body                              # error => return
          start.inc                                 # adj. stepwise for logging
          bodyRc = true                             # did something => ret code

      # Store partial slot on database
      if 0 < data.slot.len:
        let thisAcc = accounts[start]               # this account
        start.inc
        let accLeft = accounts[start .. ^1]         # shortcut for the rest
        var limit = data.slot[^1].slotHash.to(ItemKey)
        adb.putStoAndProof(sRoot, low(ItemKey), limit, data, peerID).isOkOr:
          state.register(thisAcc)                   # stash this trie fully
          state.register(accLeft)                   # stash rest and return
          trace info & ": storing partial slots failed", peer, root,
            start, nAccLeft=accLeft.len
          break body                                # error => return
        bodyRc = true                               # did something => ret code

        # Download the rest of the sub-trie
        while limit < high(ItemKey):
          let iv = ItemKeyRange.new(limit + 1, high(ItemKey))

          # Fetch from network
          let ivData = buddy.fetchStorage(sRoot, @[thisAcc[0]], iv).valueOr:
            state.register(thisAcc, iv)           # stash part. trie
            state.register(accLeft)               # stash rest and return
            trace info & ": fetching partial slots failed", peer, root, start,
              nAccLeft=accLeft.len, iv=iv.flStr, `error`=error
            break body                            # error => return

          limit = ivData.slot[^1].slotHash.to(ItemKey)
          adb.putStoAndProof(sRoot, iv.minPt, limit, ivData, peerID).isOkOr:
            state.register(thisAcc, iv)             # stash part. trie
            state.register(accLeft)                 # stash rest and return
            trace info & ": storing partial slots failed", peer, root, start,
              nAccLeft=accLeft.len, iv=iv.flStr, limit=limit.flStr
            break body                              # error => return

          # End `while` range left
        # End non-empty slot with partial range

      # End `while` accounts left
    # End `body`

  bodyRc                                            # return code

template downloadFromQueue(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    info: static[string];                           # Log message prefix
      ): bool =
  ## Async/template
  ##
  ## Process stashed unprocessed storage slots from state DB.
  ##
  ## The template will return `true` if there were some data that could be
  ## downloaded and processed.
  ##
  var bodyRc = false
  block body:
    let
      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = state.rootStr          # logging only

    # Separate download queue into lists by full/partial
    var
      fullTries: seq[(ItemKey,StoreRoot)]
      partTries: seq[(ItemKey,StoreRoot,ItemKeyRange)]
      partStart = 0                                 # start inx of `partTries[]`

    for w in state.stoItems:
      if w.data.stoLeft.len == 0:                   # `0` => `2^256``
        fullTries.add (w.key, w.data.stoRoot)
      else:
        partTries.add (w.key, w.data.stoRoot, w.data.stoLeft)

      # Remove current item from queue. Problematic items will be
      # re-queued automatically by `downloadImpl()`.
      state.delStorage w.key

    # Process full tries (all at once)
    if 0 < fullTries.len:
      if buddy.downloadImpl(state, fullTries, ItemKeyRangeMax, info):
        bodyRc = true

    # Process partial tries (one by one)
    while partStart < partTries.len:
      if buddy.ctrl.stopped:                        # roll back `partTries[]`
        for n in partStart ..< partTries.len:
          state.register(partTries[n][0], partTries[n][1], partTries[n][2])
        trace info & ": rolled back to slots queue", peer, root,
          partStart, nTriesLeft=(partTries.len - partStart)
        break

      let
        acc = @[(partTries[partStart][0], partTries[partStart][1])]
        iv = partTries[partStart][2]
      partStart.inc

      if buddy.downloadImpl(state, acc, iv, info):
        bodyRc = true
      # End `while`

  bodyRc                                            # return code

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template storageDownload*(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    accounts: seq[SnapAccount];                     # Acoounts with sub-tries
    info: static[string];                           # Log message prefix
      ) =
  ## Async/template
  ##
  block body:
    let acc = accounts
       .filterIt(not it.accBody.storageRoot.isEmpty)
       .mapIt( (it.accHash.to(ItemKey),
                it.accBody.storageRoot.Hash32.to(StoreRoot)) )

    if buddy.ctrl.stopped:
      state.register acc                            # stash data and return
      break body                                    # all done

    discard buddy.downloadImpl(state, acc, ItemKeyRangeMax, info)

    while not buddy.ctrl.stopped and
          0 < state.len and
          buddy.downloadFromQueue(state, info):
      continue

  discard                                           # visual alignment

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------
