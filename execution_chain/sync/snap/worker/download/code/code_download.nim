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
  ../../../../../db/aristo/aristo_constants,
  ../../[helpers, mpt, worker_desc],
  ./code_fetch

logScope:
  topics = "snap sync"

type
  AccCodeItem = tuple
    accPath: Hash32
    codeHash: Hash32
    data: seq[byte]

# ------------------------------------------------------------------------------
# Private helpers(s) for `queueAndDownload()`
# ------------------------------------------------------------------------------

proc storeCdeUpdated(
    adb: CacheDbRef;
    cdeQ: openArray[AccCodeItem];
    info: static[string];                           # Log message prefix
      ): Result[int,ErrorType] =
  ## Store or restore contract data on cache DB
  var nMissing = 0
  for w in cdeQ:
    if w.data.len == 0:
      adb.putMissingBlob(w.accPath, info).isOkOr:
        return err(ECacheError)                     # cannot do much, here
      nMissing.inc

    else:
      # Need to fetch account now for updating latest record
      var accData = adb.getFlatAcc(w.accPath, info).valueOr:
        return err(ECacheError)                     # cannot do much, here
      accData.dirtyCode = false                     # update account flag
      adb.putFlatAcc(w.accPath, accData, info).isOkOr:
        return err(ECacheError)                     # cannot do much, here

      # Store contract code
      adb.putFlatCode(w.accPath, w.data, info).isOkOr:
        return err(ECacheError)                     # cannot do much, here

  ok(nMissing)

proc fetchAndLockCodeList(
    adb: CacheDbRef;
    info: static[string];                           # Log message prefix
      ): Result[seq[AccCodeItem],ErrorType] =
  ## Collect some missing contract code items from cache DB
  var cdeQ = newSeqOfCap[AccCodeItem](fetchCodeBatchMax)

  for accPath in adb.walkMissingBlob():
    let accData = adb.getFlatAcc(accPath, info).valueOr:
      return err(ECacheError)                       # cannot do much, here

    cdeQ.add (accPath, accData.account.codeHash, EmptyBlob)
    if fetchCodeBatchMax <= cdeQ.len:
      break                                         # enough collected

  if cdeQ.len == 0:                                 # empty batch
    return err(ECompleted)                          # done so far

  # Remove from cache DB, so there is unique access
  for w in cdeQ:
    adb.delMissingBlob(w.accPath, info).isOkOr:
      return err(ECacheError)                      # cannot do much, here

  ok(move cdeQ)

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

      trace info & ": Requesting contract codes", peer, root, number,
        start, nCodeLeft=codeLeft.len

      let data = buddy.fetchCodes(codeLeft).valueOr:
        trace info & ": Fetching codes failed", peer, root, number,
          start=start, nCodeLeft=codeLeft.len, `error`=error
        bodyRc = typeof(bodyRc).err(error)
        break body                                  # error => return

      # Verify contracts
      for n in 0 ..< data.codes.len:                # length at most `req.len`
        let hash = data.codes[n].distinctBase.keccak256
        if hash != cdeQ[n].codeHash:
          error info & ": Code hash mismatch", peer, root, number, nth=n,
            codeHash=cdeQ[n].codeHash.toStr, fromResp=hash.toStr
        else:
          # Accept for storage
          cdeQ[n].data = data.codes[n].distinctBase
        # End `for..`

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
      adb = buddy.ctx.pool.cacheDB

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only

    # Collect some missing storage intervals from cache
    var cdeQ = adb.fetchAndLockCodeList(info).valueOr:
      bodyRc = typeof(bodyRc).err(error)
      break body

    trace info & ": Requesting contract codes", peer, root, number,
      nItems=cdeQ.len

    let
      # Fetch data from network
      rc = buddy.downloadImpl(stateRoot, number, cdeQ, info)

      # Save or restore accordingly
      nMissing = adb.storeCdeUpdated(cdeQ, info).valueOr:
        bodyRc = typeof(bodyRc).err(error)          # cannot do much, here
        break body

    # Check download result
    if rc.isErr:
      bodyRc = typeof(bodyRc).err(rc.error)
      break body

    trace info & ": Code processing ok", peer, root, number,
      nComplete=(cdeQ.len - nMissing), nMissing, syncState=($buddy.syncState)

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc                                            # visual alignment

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

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
        if error != ECompleted:
          bodyRc = typeof(bodyRc).err(error)
          break body                                # return error
        break                                       # done so far

    trace info & ": Contract code done", peer=buddy.peer, root=stateRoot.toStr,
      number, syncState=($buddy.syncState)

    # End `block body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
