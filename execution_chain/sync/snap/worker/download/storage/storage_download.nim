# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Storage Sub-MPT Downloads
## -------------------------
##
## See `README.md` in the same folder as this source file.
##

{.push raises: [].}

import
  pkg/[chronicles, chronos, stew/interval_set],
  ../../[helpers, mpt, worker_desc],
  ./storage_fetch

const
  emptyProof = seq[ProofNode].default

# ------------------------------------------------------------------------------
# Private helpers for `storageDownloadCommit()`
# ------------------------------------------------------------------------------

proc deleteAccount(
    adb: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  ?adb.delFlatAcc(accPath, info)                    # remove account record
  ?adb.delFlatSlot(accPath, info)                   # delete all slots
  ?adb.delMissingBlob(accPath, info)                # delete code accounting
  ?adb.delFlatCode(accPath, info)                   # delete contract code
  ok()

proc replaceMissingIntv(
    adb: CacheDbRef;
    accState: CacheAccMissingIntvData;
    info: static[string];
      ): Opt[void] =
  ?adb.clearMissingIntv(info)                       # clears acc and sto lists
  ?adb.putAccMissingIntv(accState, info)            # update accounts list
  ok()

# ------------------------------------------------------------------------------
# Private helpers for `downloadImpl()`
# ------------------------------------------------------------------------------

proc getQueryList(
    buddy: SnapPeerRef;
    stoQueue: openArray[WalkStoMissingIntvData];
    qStart: uint;                                   # first `stoQueue[]` item
    qLen: uint;                                     # num. of stoQueue[]` items
    info: static[string];                           # Log message prefix
      ): Result[(seq[ItemKey],seq[StoreRoot]),ErrorType] =
  ## For the argument `stoQueue[]`, collect
  ## * storage data paths (for query), and
  ## * sub-MPT storage roots for verification.
  ##
  let
    adb = buddy.ctx.pool.cacheDB
    peer {.inject,used.} = $buddy.peer              # logging only
  var
    accPaths = newSeqOfCap[ItemKey](qLen)
    stoRoots = newSeqOfCap[StoreRoot](qLen)
  for n in qStart ..< qLen:
    let
      w = stoQueue[n]
      acc = adb.getFlatAcc(w.accPath, info).valueOr:
        error info & ": Missing storage account", peer,
          accPath=w.accPath.toStr, syncState=($buddy.syncState)
        return err(ECacheError)                     # cannot do much, here
    accPaths.add w.accPath.to(ItemKey)              # FIXME use `Hash32` instead
    stoRoots.add StoreRoot(acc.account.storageRoot)

  ok((accPaths,stoRoots))

proc storeValidatedSlots(
    buddy: SnapPeerRef;                             # Snap peer
    stoRoots: openArray[StoreRoot];                 # storage roots
    stoQ: var seq[WalkStoMissingIntvData];          # to be modified
    qStart: uint;                                   # first root/queue item
    data: StorageRangesData;                        # fetch result
    ivReq: ItemKeyRange;                            # applies to last item
    info: static[string];                           # Log message prefix
      ): Result[void,ErrorType] =
  ## Process a storage slots reply message data from the fetch utility.
  ##
  let
    adb = buddy.ctx.pool.cacheDB
    peer {.inject,used.} = $buddy.peer              # logging only

  # Validate and store sub-MPT data without proof (i.e. full sub-MPTs)
  for n in 0u ..< data.slots.len.uint:
    let
      slots = data.slots[n]
      stoRoot = stoRoots[qStart + n]

    # Validate full sub-MPT.
    stoRoot.validate(ivReq.minPt, slots, emptyProof).isOkOr:
      buddy.ctrl.zombie = true                      # peer not useful
      debug info & ": Storage full sub-MPT validation failed", peer,
        stoRoot=stoRoot.toStr, nth=n, syncState=($buddy.syncState)
      return err(EValidationError)

    # Store validated full sub-MPT slot entries.
    for w in data.slots[n]:
      let accPath = stoQ[qStart + n].accPath
      adb.putFlatSlot(accPath, w.slotHash, w.slotData, info).isOkOr:
        return err(ECacheError)
    stoQ[qStart + n].data.ranges.clear()            # set MPT complete

  # Validate partial sub-MPT data with non-empty proof.
  if 0 < data.proof.len:
    let
      topInx = data.slots.len.uint
      stoRoot = stoRoots[qStart + topInx]

    # Validate slots, some partial sub-MPT for this storage sub-MPT
    let mpt = stoRoot.validate(ivReq.minPt, data.slot, data.proof).valueOr:
      buddy.ctrl.zombie = true                      # peer not useful
      debug info & ": Storage partial sub-MPT validation failed", peer,
        stoRoot=stoRoot.toStr, nProof=data.proof.len,
        syncState=($buddy.syncState)
      return err(EValidationError)

    # Store probably partial sub-MPT
    for w in data.slot:
      let accPath = stoQ[qStart + topInx].accPath
      adb.putFlatSlot(accPath, w.slotHash, w.slotData, info).isOkOr:
        return err(ECacheError)

    let rngRef = stoQ[qStart + topInx].data.ranges  # `stoQ[]` is var parameter
    if mpt.rightMost():                             # no more right leafs
      rngRef.clear()                                # set MPT complete
    else:
      discard rngRef.reduce(ivReq.minPt, data.slot[^1].slotHash.to(ItemKey))

  ok()

# ------------------------------------------------------------------------------
# Private helpers for `queueAndDownload()`
# ------------------------------------------------------------------------------

proc fetchAndLockStoList(
    adb: CacheDbRef;
    info: static[string];                           # Log message prefix
      ): Result[(seq[WalkStoMissingIntvData],uint),ErrorType] =
  ## Collect some missing storage intervals from cache DB.
  ##
  ## TODO: Collect as many partial storage sub-MPTs as possible.
  ##
  var
    stoQ = newSeqOfCap[WalkStoMissingIntvData](fetchStorageBatchMax)
    nFullMpt = -1

  for w in adb.walkStoMissingIntv:
    if 0 < w.error.len:
      error info & ": Error walking missing storage list", `error`=w.error
      return err(ECacheError)

    # Keep track of storage sub-MPTs that need to be fully allocated.
    if nFullMpt < 0:                                # currently full MPTs
      if w.data.ranges.total != 0:                  # => partial MPT
        nFullMpt = stoQ.len                         # no more full MPTs
    else:                                           # only partial MPTs follow
      if w.data.ranges.total == 0:                  # => 2^256 => full MPT
        continue                                    # ignore

    stoQ.add w                                      # add item unless seq-max
    if fetchStorageBatchMax <= stoQ.len:
      break

  if stoQ.len == 0:                                 # empty batch
    return err(ECompleted)                          # done so far

  # Remove storage items from cache DB. So there is unique access for
  # this peer. To work savely, this needs to be done outside the above
  # iterator over `walkStoMissingIntv()`.
  for w in stoQ:
    adb.delStoMissingIntv(w.accPath, info).isOkOr:
      return err(ECacheError)                       # cannot do much, here

  if nFullMpt < 0:
    nFullMpt = stoQ.len
  ok((stoQ,nFullMpt.uint))

proc saveStoUpdates(
    adb: CacheDbRef;
    stoQueue: openArray[WalkStoMissingIntvData];
    info: static[string];                           # Log message prefix
      ): Result[int,ErrorType] =
  ## Post process updated storage sub-MPT. The corresponding accounting data
  ## are updated on the cache DB.
  ##
  var (nPartial, nErrors) = (0,0)
  for w in stoQueue:

    # Save back incomplete sub-MPT. Store updated interval. The corresounding
    # accounts record need not be updated. The `dirtyStorage` remains `true`.
    if 0 < w.data.ranges.chunks():
      nPartial.inc
      adb.putStoMissingIntv(w.accPath, w.data, info).isOkOr:
        nErrors.inc                                 # cannot do much, here
      continue

    # Save/update complete sub-MPT. Mark it complete in the accounts record.
    # Note that the `StoMissingIntv` table entry was deleted. So, according
    # to storage sub-MPT rules, it must not be restored and kept
    # missing/deleted.
    var data = adb.getFlatAcc(w.accPath, info).valueOr:
      nErrors.inc                                   # cannot do much, here
      continue
    data.dirtyStorage = false

    # Save update
    adb.putFlatAcc(w.accPath, data, info).isOkOr:
      nErrors.inc                                   # cannot do much, here
      continue

  if 0 < nErrors:
    return err(ECacheError)
  ok(nPartial)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template downloadImpl(
    buddy: SnapPeerRef;                             # Snap peer
    stateRoot: StateRoot;
    number: BlockNumber;                            # for logging only
    stoQ: var seq[WalkStoMissingIntvData];          # to be modified
    qStart: uint;                                   # first `stoQueue[]` item
    qLen: uint;                                     # num. of stoQueue[]` items
    ivReq: ItemKeyRange;                            # Interval to fetch
    info: static[string];                           # Log message prefix
      ): auto =
  ## Async/template
  ##
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:
    let
      (accPaths,stoRoots) = buddy.getQueryList(
           stoQ, qStart, qLen, info).valueOr:
        bodyRc = typeof(bodyRc).err(error)
        break body

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only
    var
      start: uint = qStart

    # Fetch storage slots from list `accPaths[]`
    while start < accPaths.len.uint:
      let accLeft: seq[ItemKey] = accPaths[start .. ^1]

      trace info & ": Requesting storage slots", peer, root, number,
        start, nAccLeft=accLeft.len

      # Fetch from network
      let data = buddy.fetchStorage(stateRoot, accLeft, ivReq).valueOr:
        trace info & ": Fetching slots failed", peer, root, number,
          start=start, nAccLeft=accLeft.len, `error`=error
        bodyRc = typeof(bodyRc).err(error)
        break body                                # error => return

      buddy.storeValidatedSlots(
          stoRoots, stoQ, qStart, data, ivReq, info).isOkOr:
        bodyRc = typeof(bodyRc).err(error)
        break body

      let nProcessed = data.slots.len + (0 < data.proof.len).ord

      trace info & ": Stored slots", peer, root, number, start=start,
        nProcessed, nAccLeft=(accLeft.len - nProcessed), ivReq=ivReq.flStr

      start += nProcessed.uint
      # End `while` accounts left

    bodyRc = typeof(bodyRc).ok()
    # End `body`

  bodyRc                                            # return code

template queueAndDownload(
    buddy: SnapPeerRef;                             # Snap peer
    stateRoot: StateRoot;
    number: BlockNumber;                            # for logging only
    info: static[string];                           # Log message prefix
      ): auto =
  ## Async/template
  ##
  var bodyRc = Result[void,ErrorType].ok()
  block body:
    let
      adb = buddy.ctx.pool.cacheDB

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only

    # Collect some missing storage intervals from cache
    var (stoQ, nFullMpt) = adb.fetchAndLockStoList(info).valueOr:
      bodyRc = typeof(bodyRc).err(error)            # maybe completed, already
      break body

    # Process full tries (all at once)
    if 0 < nFullMpt:
      # Full sub-MPTs to download
      trace info & ": Requesting from slots queue", peer, root, number,
        nFullStoMPTs=nFullMpt
      buddy.downloadImpl(
          stateRoot, number, stoQ, 0, nFullMpt, ItemKeyRangeMax, info).isOkOr:
        adb.saveStoUpdates(stoQ, info).isOkOr:      # restore `stoQ[]`
          bodyRc = typeof(bodyRc).err(ECacheError)  # oops
          break body
        bodyRc = typeof(bodyRc).err(error)
        break body

    # Process partial tries (one by one)
    var partStart = nFullMpt
    while partStart < stoQ.len.uint:
      if buddy.ctrl.stopped:
        bodyRc = typeof(bodyRc).ok()
        break body
      let
        rngRef = stoQ[partStart].data.ranges        # `stoQ[]` is var parameter
        iv = rngRef.fetchLeast(high UInt256).expect "valid intv"
      trace info & ": Requesting from slots queue", peer,
        nPartStoMPTs=(stoQ.len.uint - partStart), iv=iv.flStr
      buddy.downloadImpl(
          stateRoot, number, stoQ, partStart, 1u, iv, info).isOkOr:
        adb.saveStoUpdates(stoQ, info).isOkOr:      # restore `stoQ[]`
          bodyRc = typeof(bodyRc).err(ECacheError)  # oops
          break body
        bodyRc = typeof(bodyRc).err(error)
        break body

    # Save rest if there is any (i.e. partially completes storage tries)
    let nPartial {.inject,used.} = adb.saveStoUpdates(stoQ, info).valueOr:
      bodyRc = typeof(bodyRc).err(error)
      trace info & ": Storage processing failed", peer, root, number,
        syncState=($buddy.syncState), `error`=bodyRc.error
      break body

    trace info & ": Storage processing ok", peer, root, number,
      nComplete=(stoQ.len - nPartial), nPartial,
      syncState=($buddy.syncState)

    # End `block body`

  bodyRc                                            # visual alignment

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

proc storageDownloadCommit*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Result[void,ErrorType] =
  ## Get ready for state froward procedure using BAL forwarding.
  ##
  ## In particular, partial storage sub-MPTs, its correspnding accounts,
  ## and contract codes are deleted.
  ##
  let adb = ctx.pool.cacheDB

  # Collect paths for partial subMPTs.
  var accPaths: seq[Hash32]
  for w in adb.walkStoMissingIntv:
    if 0 < w.error.len:
      error info & ": Error walking missing storage list", `error`=w.error
      return err(ECacheError)
    accPaths.add w.accPath

  if 0 < accPaths.len:
    # Delete all partial sub-MPTs.
    var accState = adb.getAccMissingIntv(info).valueOr:
      return err(ECacheError)

    for accPath in accPaths:
      adb.deleteAccount(accPath, info).isOkOr:
        return err(ECacheError)
      accState.ranges.merge(accPath.to(ItemKey))    # update range

    adb.replaceMissingIntv(accState, info).isOkOr:  # update accounting
      return err(ECacheError)

  chronicles.info info & ": Cleared storage sub-MPTs", nMpt=accPaths.len
  ok()

template storageDownload*(
    buddy: SnapPeerRef;                             # Snap peer
    stateRoot: StateRoot;
    number: BlockNumber;                            # for logging only
    info: static[string];                           # Log message prefix
      ): auto =
  ## Async/template
  ##
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:

    while not buddy.ctrl.stopped:
      buddy.queueAndDownload(stateRoot, number, info).isOkOr:
        if error != ECompleted:
          bodyRc = typeof(bodyRc).err(error)
          break body                                # return error
        break                                       # done so far

    trace info & ": Storage done", peer=buddy.peer, root=stateRoot.toStr,
      number, syncState=($buddy.syncState)

    # End `block body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
