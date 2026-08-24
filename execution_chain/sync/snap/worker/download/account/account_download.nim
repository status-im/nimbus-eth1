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
  ../../[extra_types, helpers, mpt, worker_desc],
  ./account_fetch

declareGauge nec_snap_accounts_coverage, "" &
  "Factor of accumulated account ranges"

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

proc accountDownloadMetricsReset*(ctx: SnapCtxRef) =
  metrics.set(nec_snap_accounts_coverage, 0)

proc accountDownloadMetricsUpdate*(ctx: SnapCtxRef) =
  metrics.set(nec_snap_accounts_coverage, 1.0 - ctx.accUnproc.totalRatio)

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
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:
    let
      ctx = buddy.ctx
      adb = ctx.pool.cacheDB

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging ony

      ivReq = ctx.accUnproc.fetchLeast(unprocAccountsRangeMax).valueOr:
        trace info & ": Currently no more unpocessed", peer, root, number,
          syncState=($buddy.syncState)
        bodyRc = typeof(bodyRc).err(ECompleted)
        break body                                  # return err()

    trace info & ": Requesting account range", peer, root, number,
      ivReq=ivReq.flStr, syncState=($buddy.syncState)

    let
      data = buddy.fetchAccounts(stateRoot, ivReq).valueOr:
        ctx.accUnproc.commit(ivReq, ivReq)          # registry roll back
        trace info & ": Account download failed", peer, root, number,
          ivReq=ivReq.flStr, syncState=($buddy.syncState), `error`=error
        bodyRc = typeof(bodyRc).err(error)
        break body                                  # return err()

      nAccounts {.inject,used.} = data.accounts.len # logging only
      nProof {.inject,used.} = data.proof.len       # logging only

      mpt = stateRoot.validate(ivReq.minPt, data.accounts, data.proof).valueOr:
        buddy.ctrl.zombie = true                    # peer not useful
        debug info & ": Accounts validation failed", peer, root,number,
          ivReq=ivReq.flStr, nAccounts, nProof, syncState=($buddy.syncState)
        bodyRc = typeof(bodyRc).err(EValidationError)
        break body                                  # return err()

      # Make certain that the right end of the downloaded range does not
      # exceed the requested range. Processing extra accounts might overwrite
      # the book keeping on the already stored accounts.
      limit = if mpt.rightMost: high(ItemKey)
              else: min(data.accounts[^1].accHash.to(ItemKey), ivReq.maxPt)

    # Save accounts on flat tables
    for w in data.accounts:
      if limit < w.accHash.to(ItemKey):             # ignore excess entries
        break                                       # exit `for()` loop

      let
        acc = cast[Account](w.accBody)              # distinct field diffs only
        dirtyStorage =
          if acc.storageRoot == EMPTY_ROOT_HASH: false
          else:
            let ikrs = ItemKeyRangeSet.init ItemKeyRangeMax
            adb.putStoMissingIntv(w.accHash, ikrs, info).isOkOr:
              bodyRc = typeof(bodyRc).err(ECacheError)
              ctx.accUnproc.commit(ivReq, ivReq)    # registry roll back
              break body                            # return err()
            true
        dirtyCode =
          if acc.codeHash == EMPTY_CODE_HASH: false
          else:
            adb.putMissingBlob(w.accHash, info).isOkOr:
              bodyRc = typeof(bodyRc).err(ECacheError)
              ctx.accUnproc.commit(ivReq, ivReq)    # registry roll back
              break body                            # return err()
            true

      adb.putFlatAcc(w.accHash, dirtyStorage, dirtyCode, acc, info).isOkOr:
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

    debug info & ": Accounts downloaded and cached", peer, root, number,
      ivResp=(ivReq.minPt,limit).flStr, nAccounts, nProof,
      syncState=($buddy.syncState)

    bodyRc = typeof(bodyRc).ok()

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
