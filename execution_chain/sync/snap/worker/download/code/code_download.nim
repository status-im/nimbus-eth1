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
  std/[sequtils, typetraits],
  pkg/[chronicles, chronos],
  ../../[helpers, cache_db, delete_account, worker_desc],
  ./code_fetch

logScope:
  topics = "snap sync"

type
  AccCodeItem = tuple
    accPath: Hash32
    codeHash: Hash32
    processed: bool

# ------------------------------------------------------------------------------
# Private helper(s) for `downloadImpl()`
# ------------------------------------------------------------------------------

proc storeValidatedCodes(
    buddy: SnapPeerRef;
    cdeQ: var seq[AccCodeItem];                     # will be updated
    qStart: int;                                    # first queue item
    data: ByteCodesPacket;
    info: static[string];
      ): Result[void,ErrorType] =
  ## Process a contract codes reply message data from the fetch utility.
  ##
  let adb = buddy.ctx.pool.cacheDB

  # Verify and save contract codes. The request was for `cdeQ[qStart .. ^1]`,
  # surplus reply entries are ignored (`fetchCodes()` rejects such replies.)
  for n in 0 ..< min(cdeQ.len - qStart, data.codes.len):
    let
      code = data.codes[n].distinctBase
      hash = code.keccak256
    template cdeItem: untyped =
      cdeQ[qStart + n]

    if hash != cdeItem.codeHash:
      error info & ": Code hash mismatch", peer=buddy.peer,
        codeHash=cdeItem.codeHash.toStr, fromResp=hash.toStr
      buddy.ctrl.zombie = true                      # peer not useful
      return err(EValidationError)

    # Store contract code
    if 0 < code.len:
      # Need to fetch account now for updating latest record
      var accData = adb.getFlatAcc(cdeItem.accPath, info).valueOr:
        return err(ECacheError)                     # cannot do much, here
      accData.dirtyCode = false                     # update account flag
      adb.putFlatAcc(cdeItem.accPath, accData, info).isOkOr:
        return err(ECacheError)                     # cannot do much, here

      # Save contract code and unlock
      adb.delCodeLock(cdeItem.accPath,info).isOkOr: # sub-MPT not in-use anymore
        return err(ECacheError)                     # cannot do much, here
      adb.putFlatCode(cdeItem.accPath,code, info).isOkOr:
        return err(ECacheError)                     # cannot do much, here

    cdeItem.processed = true
    # End `for..`

  ok()

# ------------------------------------------------------------------------------
# Private helpers for `queueAndDownload()`
# ------------------------------------------------------------------------------

proc fetchAndLockCodeList(
    buddy: SnapPeerRef;
    info: static[string];                           # Log message prefix
      ): Result[seq[AccCodeItem],ErrorType] =
  ## Collect some missing contract code items from cache DB
  let adb = buddy.ctx.pool.cacheDB
  var cdeQ = newSeqOfCap[AccCodeItem](fetchCodeBatchMax)

  for accPath in adb.walkMissingBlob():
    let accData = adb.getFlatAcc(accPath, info).valueOr:
      return err(ECacheError)                       # cannot do much, here

    # Check whether the code request for this account was cached at a
    # previous session and the corresponding data record for this account
    # has not been updated, yet.
    if buddy.ctx.accUnproc.covered accPath.to(ItemKey):
      continue                                      # come back later

    cdeQ.add (accPath, accData.account.codeHash, false)
    if fetchCodeBatchMax <= cdeQ.len:
      break                                         # enough collected

  if cdeQ.len == 0:                                 # empty batch
    return err(ECompleted)                          # done so far

  # Remove from cache DB, so there is unique access
  for w in cdeQ:
    adb.putCodeLock(w.accPath,info).isOkOr:         # mark sub-MPT in-use
      return err(ECacheError)                       # cannot do much, here
    adb.delMissingBlob(w.accPath, info).isOkOr:
      return err(ECacheError)                       # cannot do much, here

  ok(move cdeQ)

proc commitCodeUpdates(
    buddy: SnapPeerRef;
    cdeQ: openArray[AccCodeItem];
    info: static[string];                           # Log message prefix
      ): Result[int,ErrorType] =
  ## Post process updated contract code items. The corresponding accounting
  ## data are updated on the cache DB.
  ##
  let adb = buddy.ctx.pool.cacheDB
  var nUnprocessed = 0
  for w in cdeQ:

    # Check whether contract code was updated.
    if not w.processed:
      # Store back missing contract code record
      adb.putMissingBlob(w.accPath, info).isOkOr:
        return err(ECacheError)                     # cannot do much, here
      nUnprocessed.inc

    # Clear lock
    adb.delCodeLock(w.accPath,info).isOkOr:         # mark sub-MPT in-use
      return err(ECacheError)                       # cannot do much, here

  ok(move nUnprocessed)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template downloadImpl(
    buddy: SnapPeerRef;                             # Snap peer
    stateRoot: StateRoot;
    number: BlockNumber;                            # for logging only
    cdeQ: var seq[AccCodeItem];
    info: static[string];                           # Log message prefix
      ): auto =
  ## Async/template
  ##
  ## The template will return `true` if there were some data that could be
  ## downloaded and processed.
  ##
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:
    let
      req =  cdeQ.mapIt(CodeHash it.codeHash)

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only
    var
      start = 0

    # Fetch storage contract codes from argument list `accounts`
    while start < req.len:
      let codeLeft: seq[CodeHash] = req[start .. ^1]

      let data = buddy.fetchCodes(codeLeft).valueOr:
        if 0 < start:
          break
        bodyRc = typeof(bodyRc).err(error)
        break body                                  # error => return

      # Store and validate data
      buddy.storeValidatedCodes(cdeQ, start, data, info).isOkOr:
        bodyRc = typeof(bodyRc).err(error)
        break body                                  # exit => error

      start += data.codes.len                       # next round?
      # End `while..`

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc
 
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
      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only

    # Collect some missing contract code addresses from cache DB
    var cdeQ = buddy.fetchAndLockCodeList(info).valueOr:
      bodyRc = typeof(bodyRc).err(error)
      break body

    trace info & ": Requesting contract codes", peer, root, number,
      nCode=cdeQ.len

    # Fetch data from network, validate and store it. The  `downloadImpl()`
    # directive will store any success in the `cdeQ[]` list.
    buddy.downloadImpl(stateRoot, number, cdeQ, info).isOkOr:
      buddy.commitCodeUpdates(cdeQ, info).isOkOr:   # restore by `stoQ[]`
        bodyRc = typeof(bodyRc).err(ECacheError)
        break body                                  # oops, serious error
      bodyRc = typeof(bodyRc).err(error)
      break body

    let nLeft = buddy.commitCodeUpdates(cdeQ, info).valueOr:
      trace info & ": Contract code processing failed", peer, root, number,
        syncState=($buddy.syncState), `error`=bodyRc.error
      bodyRc = typeof(bodyRc).err(error)
      break body

    chronicles.info info & ": Contract codes saved", peer, root, number,
      nCodes=(cdeQ.len-nLeft), nUnprocessed=nLeft, syncState=($buddy.syncState)

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc                                            # visual alignment

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template codeDownloadCommit*(
    ctx: SnapCtxRef;
    timer: TimerDataRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Get ready for state forward procedure using BAL.
  ##
  ## In particular, for missing contract codes the account must be re-fetched
  ## so that the code hash can be updated. This is needed for fetching the
  ## updated contract code.
  ##
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:
    if not ctx.accUnproc.synced():
      error info & ": Cannot commit unsynced accounts ranges"
      bodyRc = typeof(bodyRc).err(ENoDataAvailable)
      break body
    if ctx.accUnproc.borrowed.chunks != 0:          # clean accounts registry?
      error info & ": Cannot update dirty unprocessed ranges",
        nBorrowedChunks=ctx.accUnproc.borrowed.chunks
      bodyRc = typeof(bodyRc).err(ENoDataAvailable)
      break body                                    # failed

    let adb = ctx.pool.cacheDB

    # Process missing contract codes.
    var nMissCode {.inject,used.} = 0
    for accPath in adb.walkMissingBlob():
      # Mark account deleted while leaving the record in the database.
      discard ctx.accUnproc.unprocessed.merge(accPath.to(ItemKey))
      nMissCode.inc
      timer.yieldThread()

    # Delete all accounts for contract code storage locks which should
    # never happen in the first place.
    let accPaths = adb.walkCodeLock.toSeq()
    for accPath in accPaths:
      ctx.deleteAccount(accPath, timer, info).isOkOr:
        bodyRc = typeof(bodyRc).err(ECacheError)
        break body

    if 0 < accPaths.len or 0 < nMissCode:
      warn info & ": Cleared locked contract codes",
        nMissCode, nCodeLock=accPaths.len

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc

template codeDownload*(
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
        bodyRc = typeof(bodyRc).err(error)
        break body                                  # return error

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
