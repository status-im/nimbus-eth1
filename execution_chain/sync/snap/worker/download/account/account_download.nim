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
  pkg/[chronicles, chronos, metrics, stew/interval_set],
  ../../[helpers, cache_db, mpt_build, update, worker_desc],
  ./account_fetch

logScope:
  topics = "snap sync"

declareGauge nec_snap_accounts_coverage, "" &
  "Factor of accumulated account ranges"

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

proc accountDownloadMetricsReset*(ctx: SnapCtxRef) =
  metrics.set(nec_snap_accounts_coverage, 0)
  ctx.resetEta()

proc accountDownloadMetricsUpdate*(ctx: SnapCtxRef) =
  if ctx.accUnproc.synced():
    let w = 1.0 - ctx.accUnproc.totalRatio
    metrics.set(nec_snap_accounts_coverage, w)
    ctx.updateEta w

proc accountDownloadCommit*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Result[void,ErrorType] =
  ## Get ready for state froward procedure using BAL forwarding.
  ##
  ## In particular, write back the accounts accounting ranges to the
  ## cache DB.
  ##
  # Update missing accounts list
  if not ctx.accUnproc.synced():
    error info & ": Cannot commit unsynced accounts ranges"
    return err(ENoDataAvailable)
  if ctx.accUnproc.borrowed.chunks != 0:
    error info & ": Cannot commit dirty unprocessed ranges"
    return err(EDirtyData)

  let adb = ctx.pool.cacheDB
  var accState = adb.getAccMissingIntv(info).valueOr:
    return err(ECacheError)

  # Note that `ctx.accUnproc.unprocessed` is a reference to data that will
  # be written back to the cache DB. The `ctx.accUnproc` object will not be
  # changed.
  accState.ranges = ctx.accUnproc.unprocessed
  adb.putAccMissingIntv(accState, info).isOkOr:
    return err(ECacheError)

  accState.ranges = ItemKeyRangeSet(nil)            # force GC to release ref
  ctx.accUnproc.clear()                             # reset global account
  ok()

template accountDownload*(
    buddy: SnapPeerRef;                             # Snap peer
    stateRoot: StateRoot;
    number: BlockNumber;                            # for logging only
    info: static[string];                           # Log message prefix
      ): auto =
  ## Async/template
  ##
  ## On success, the template returns a list of accounts for storage and
  ## code processing.
  ##
  ## A successful return code is `true` if a new list of accounts was
  ## downloaded, and `false` if there were refreshed accounts, only.
  ##
  var bodyRc = Result[bool,ErrorType].err(EGeneric)
  block body:
    let
      ctx = buddy.ctx
      adb = ctx.pool.cacheDB

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging ony

      ivReq {.inject.} =
        ctx.accUnproc.fetchLeast(unprocAccountsRangeMax).valueOr:
          bodyRc = typeof(bodyRc).err(ECompleted)
          break body                                # return err()

      data = buddy.fetchAccounts(stateRoot, ivReq).valueOr:
        ctx.accUnproc.commit(ivReq, ivReq)          # registry roll back
        bodyRc = typeof(bodyRc).err(error)
        break body                                  # return err()

      nAccounts {.inject,used.} = data.accounts.len # logging only
      nProof {.inject,used.} = data.proof.len       # logging only

      mpt = stateRoot.validate(ivReq.minPt, data.accounts, data.proof).valueOr:
        buddy.ctrl.zombie = true                    # peer not useful
        debug info & ": Accounts validation failed", peer, root, pivot=number,
          ivReq=ivReq.flStr, nAccounts, nProof, syncState=($buddy.syncState)
        ctx.accUnproc.commit(ivReq, ivReq)          # registry roll back
        bodyRc = typeof(bodyRc).err(EValidationError)
        break body                                  # return err()

      # Make certain that the right end of the downloaded range does not
      # exceed the requested range. Processing extra accounts might overwrite
      # the book keeping on the already stored accounts.
      limit = if mpt.rightMost: high(ItemKey)
              else: min(data.accounts[^1].accHash.to(ItemKey), ivReq.maxPt)

    # Save accounts on flat tables
    var refreshOnly {.inject.} = true               # init for return code
    for w in data.accounts:
      if limit < w.accHash.to(ItemKey):             # ignore excess entries
        break                                       # exit `for()` loop

      let acc = cast[Account](w.accBody)            # distinct field diffs only

      # Check whether this account was marked for re-fetch while storage
      # data or contract code records already exist on the cache DB.
      let maybe = adb.getFlatAcc(w.accHash, info)
      if maybe.isSome():
        let prvData = maybe.unsafeGet()
        trace info & ": Updating account record", peer, root, pivot=number,
          accPath=w.accHash.toStr, storageRoot=acc.storageRoot.toStr,
          codeHash=acc.codeHash.toStr, syncState=($buddy.syncState)

      else:
        refreshOnly = false                         # not a refreshed account

        if acc.storageRoot != EMPTY_ROOT_HASH:
          var data: CacheStoMissingIntvData
          data.ranges = ItemKeyRangeSet.init ItemKeyRangeMax
          adb.putStoMissingIntv(w.accHash, data, info).isOkOr:
            bodyRc = typeof(bodyRc).err(ECacheError)
            ctx.accUnproc.commit(ivReq, ivReq)      # registry roll back
            break body                              # return err()

        if acc.codeHash != EMPTY_CODE_HASH:
          adb.putMissingBlob(w.accHash, info).isOkOr:
            bodyRc = typeof(bodyRc).err(ECacheError)
            ctx.accUnproc.commit(ivReq, ivReq)      # registry roll back
            break body                              # return err()

      adb.putFlatAcc(w.accHash, acc, info).isOkOr:
        bodyRc = typeof(bodyRc).err(ECacheError)
        ctx.accUnproc.commit(ivReq, ivReq)          # registry roll back
        break body
      # End `for w..`

    # Update missing intervals registry
    if limit < ivReq.maxPt:
      ctx.accUnproc.commit(ivReq, limit+1, ivReq.maxPt)
    else:
      ctx.accUnproc.commit(ivReq)

    # Update metrics
    ctx.accountDownloadMetricsUpdate()

    debug info & ": Accounts saved", peer, root, pivot=number,
      ivResp=(ivReq.minPt,limit).flStr, nAccounts, nProof, refreshOnly,
      syncState=($buddy.syncState)

    bodyRc = typeof(bodyRc).ok(refreshOnly)

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
