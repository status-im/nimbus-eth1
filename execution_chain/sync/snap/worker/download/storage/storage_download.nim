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

func isFullRange(itrs: ItemKeyRangeSet): bool =
  # Defensive encoding of a full range check. Solely testing `total; == 0`
  # leaves room for the case that the range is empty which is an illegal
  # situation but it can handled with savely.
  itrs.total == 0 and                              # => 0 or 2^256
  itrs.chunks == 1                                 # => one intv => full MPT

# ------------------------------------------------------------------------------
# Private helpers for `downloadImpl()`
# ------------------------------------------------------------------------------

proc getQueryList(
    buddy: SnapPeerRef;
    stoQueue: openArray[WalkStoMissingIntvData];
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
    accPaths = newSeqOfCap[ItemKey](stoQueue.len)
    stoRoots = newSeqOfCap[StoreRoot](stoQueue.len)
  for w in stoQueue:
    let acc = adb.getFlatAcc(w.accPath, info).valueOr:
      error info & ": Missing storage account", peer,
        accPath=w.accPath.toStr, syncState=($buddy.syncState)
      return err(ECacheError)                       # cannot do much, here
    accPaths.add w.accPath.to(ItemKey)              # FIXME use `Hash32` instead
    stoRoots.add StoreRoot(acc.account.storageRoot)

  ok((accPaths, stoRoots))

proc storeValidatedSlots(
    buddy: SnapPeerRef;                             # Snap peer
    stoRoots: openArray[StoreRoot];                 # storage roots
    stoQ: var seq[WalkStoMissingIntvData];          # to be modified
    qStart: int;                                    # first root/queue item
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
  for n in 0 ..< data.slots.len:
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
      topInx = data.slots.len
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
      ): Result[seq[WalkStoMissingIntvData],ErrorType] =
  ## Collect storage sub-MPT missing slot intervals records from the cache
  ## DB and remove these records. So the current peer is guaranteed unique
  ## access to these records.
  ##
  ## Unless error, the functions returns a non-empty list of eiter all
  ## partially or all fully missing sub-MPT records.
  ##
  ## Partially missing sub-MPTs have priority over fully missing ones. If
  ## a partially missing sub-MPT is returned. the list will have exactly
  ## one entry.
  ##
  ## The intended effect is, that peers workin in quasi-parallel will clean
  ## up/complete these kind of missing sub-MPTs first.
  ##
  var
    stoFullQ = newSeqOfCap[WalkStoMissingIntvData](fetchStorageBatchMax)
    stoPartQ = newSeqOfCap[WalkStoMissingIntvData](1)

  # Collect as full and partial storage sub-MPTs in different queues.
  for w in adb.walkStoMissingIntv:
    if 0 < w.error.len:
      error info & ": Error walking missing storage list", `error`=w.error
      return err(ECacheError)

    if w.data.ranges.isFullRange():
      stoFullQ.add w
      if fetchStorageBatchMax <= stoFullQ.len:      # add item unless seq-max
        break
    else:                                           # => partial MPT
      stoPartQ.add w
      break                                         # only a single item queue

  # Remove storage items from cache DB. So there is unique access for
  # this peer. To work savely, this needs to be done outside the above
  # iterator over `walkStoMissingIntv()`.
  if 0 < stoPartQ.len:
    adb.delStoMissingIntv(stoPartQ[0].accPath, info).isOkOr:
      return err(ECacheError)                       # cannot do much, here
    return ok(stoPartQ)

  if stoFullQ.len == 0:                             # empty batch
    return err(ECompleted)                         # done so far

  # Same as for `stoPartQ`.
  for w in stoFullQ:
    adb.delStoMissingIntv(w.accPath, info).isOkOr:
      return err(ECacheError)                       # cannot do much, here

  ok(stoFullQ)

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

    # Save back incomplete sub-MPT. Store updated interval of missing slots.
    # The corresounding accounts record needs not to be updated.
    # The `dirtyStorage` flag just remains `true`.
    if 0 < w.data.ranges.chunks():
      nPartial.inc
      adb.putStoMissingIntv(w.accPath, w.data, info).isOkOr:
        nErrors.inc                                 # cannot do much, here
      continue

    # Save/update complete sub-MPT. There is no updated interval of
    # missing slots record to save back. The records are omitted. Reset
    # the corresounding accounts record flag `StoMissingIntv`.
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
    ivReq: ItemKeyRange;                            # Interval to fetch
    info: static[string];                           # Log message prefix
      ): auto =
  ## Async/template
  ##
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:
    let
      (accPaths, stoRoots) = buddy.getQueryList(stoQ, info).valueOr:
        bodyRc = typeof(bodyRc).err(error)
        break body
      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only

    # Fetch storage slots from list `accPaths[]`
    var start = 0
    while start < accPaths.len:
      let accLeft: seq[ItemKey] = accPaths[start .. ^1]

      # Fetch from network
      let data = buddy.fetchStorage(stateRoot, accLeft, ivReq).valueOr:
        if 0 < start:
          break
        bodyRc = typeof(bodyRc).err(error)
        break body                                  # error => return

      # Store and validate data
      buddy.storeValidatedSlots(
           stoRoots, stoQ, start, data, ivReq, info).isOkOr:
        bodyRc = typeof(bodyRc).err(error)
        break body                                  # exit => error

      # Prepare next cycle
      start += data.slots.len + (0 < data.proof.len).ord

      if buddy.ctrl.stopped:
        break
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
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:
    let
      adb = buddy.ctx.pool.cacheDB

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only

    # Collect some missing storage intervals from cache. If the function
    # `fetchAndLockStoList()` succeeds, it will return a non-empty list.
    var stoQ = adb.fetchAndLockStoList(info).valueOr:
      bodyRc = typeof(bodyRc).err(error)            # maybe completed, already
      break body

    let ivReq =
      # If the first entry is a fully missing sub-MPT, then all queue enties
      # are fully missing sub-MPTs.
      if stoQ[0].data.ranges.isFullRange():
        trace info & ": Requesting full storage sub-MPTs", peer, root, number,
          nStoMPTs=stoQ.len
        ItemKeyRangeMax                             # sort of `don't care` entry
      else:
        doAssert stoQ.len == 1
        let iv = stoQ[0].data.ranges.fetchLeast(high UInt256).valueOr:
          raiseAssert "Empty range unexpected" &
            ", ranges=" & stoQ[0].data.ranges.flStr
        iv                                          # download partial sub-MPT

    # Download a list of full sub-MPTs, or a single one with a sub-range.
    # The `downloadImpl()` directive below will store any success in the
    # `stoQ[]` list.
    buddy.downloadImpl(stateRoot, number, stoQ, ivReq, info).isOkOr:
      adb.saveStoUpdates(stoQ, info).isOkOr:        # restore by `stoQ[]`
        bodyRc = typeof(bodyRc).err(ECacheError)
        break body                                  # oops, serious error
      bodyRc = typeof(bodyRc).err(error)
      break body

    # Save rest if there is any (i.e. partially completes storage tries)
    let nPartial {.inject,used.} = adb.saveStoUpdates(stoQ, info).valueOr:
      trace info & ": Storage processing failed", peer, root, number,
        syncState=($buddy.syncState), `error`=bodyRc.error
      bodyRc = typeof(bodyRc).err(error)
      break body

    chronicles.info info & ": Storage sub-MPTs saved", peer, root,
      number, nComplete=(stoQ.len - nPartial), nPartial,
      syncState=($buddy.syncState)

    bodyRc = typeof(bodyRc).ok()
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
  ## Download storage dara.
  ##
  ## Unless a serious error occurs, it stops with error `ECompleted` if the
  ## storade batch wss exhaused, and with `ok()` if the peer has stopped.
  ##
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:

    while not buddy.ctrl.stopped:
      buddy.queueAndDownload(stateRoot, number, info).isOkOr:
        bodyRc = typeof(bodyRc).err(error)
        break body                                  # return error

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
