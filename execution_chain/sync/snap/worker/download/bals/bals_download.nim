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
  std/strutils,
  pkg/[chronicles, chronos, minilru],
  ../../../../../block_access_list/bal_utils,
  ../../../../wire_protocol,
  ../../[helpers, mpt, worker_desc],
  ./bals_fetch

logScope:
  topics = "snap sync"

type
  ReqEnv = object
    hdrs: seq[Header]
    balReq: BlockAccessListsRequest

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc verifyArgs(
    minBn: BlockNumber;
    nBals: int;
    peer: string;                                   # for error logging
    info: static[string];                           # Log message prefix
      ): Opt[void] =
  if minBn == 0 or                                  # so `minBn-1` makes sense
     nBals <= 0:                                    # makes no sense
    debug ": BALs download zero args error", peer, minBn, nBals
    return err()

  if nProcBalDwnldBatchMax < nBals or               # out of bounds
     high(BlockNumber) - minBn < (nBals - 1).uint:
    error ": BALs download request too large", peer, minBn, nBals
    return err()

  ok()

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getReqEnv(
    buddy: SnapPeerRef;                             # Snap peer
    minBn: BlockNumber;                             # first BAL
    nBals: int;                                     # max number of BALs
    info: static[string];                           # Log message prefix
      ): Result[ReqEnv,ErrorType] =
  ## Assemble BAL request from headers on the cache DB.
  let
    ctx = buddy.ctx
    db = ctx.pool.cacheDB
    maxBn = minBn + nBals.uint - 1

  # Get first header. So one can mostly avoid compiling block hashes by
  # using the child header parent, instead.
  let firstHdr = db.getHeader(minBn, info).valueOr:
    return err(ENoDataAvailable)                    # no headers available

  var q = ReqEnv(
    hdrs:   newSeqOfCap[Header](nBals),
    balReq: BlockAccessListsRequest(
      blockHashes: newSeqOfCap[Hash32](nBals)))
  q.hdrs.add firstHdr

  # Check whether BALs are available, at all.
  let headSlot = firstHdr.slotNumber
  if not ctx.chain.com.isAmsterdamOrLater(firstHdr.timestamp) or
     headSlot.isNone() or
     not firstHdr.isWithinBalRetentionPeriod(headSlot.unsafeGet):
    return err(EMissingBalSupport)                  # no BALs available

  for bn in minBn+1 .. maxBn:
    let h = db.getHeader(bn, info).valueOr:
      break
    q.hdrs.add h
    q.balReq.blockHashes.add h.parentHash

  doAssert 0 < q.hdrs.len                           # FIXME, will go away
  doAssert q.hdrs.len == q.balReq.blockHashes.len + 1

  # Fetch or compute last block hash
  let topHdr = if q.hdrs.len < nBals: Header()
               else: db.getHeader(maxBn + 1, info).valueOr: Header()
  if topHdr.number == maxBn + 1:
    q.balReq.blockHashes.add topHdr.parentHash
  else:
    q.balReq.blockHashes.add q.hdrs[^1].computeBlockHash

  doAssert q.hdrs.len == q.balReq.blockHashes.len   # FIXME, will go away

  ok(q)

proc storeBals(
    buddy: SnapPeerRef;                             # Snap peer
    rawBals: openArray[RawBlockAccessList];         # raw BALs
    hdrs: openArray[Header];
    startInx: int;                                  # index of first header
    info: static[string];                           # Log message prefix
       ): Result[int,ErrorType] =
  ## Verify BALs and store on cache DB. The return code of the `storeBals()`.
  let db = buddy.ctx.pool.cacheDB

  template hdr(n: int): untyped = hdrs[startInx+n]  # shortcut
  for n in 0 ..< rawBals.len:

    # Verify and decode BALs
    let bal = rawBals[n].decodeBlockAccessList(hdr(n)).valueOr:
      error info & ": BAL verification failed", number=hdr(n).number
      return err(EValidationError)

    # Store BAL on cache DB
    db.putBal(hdr(n).number, bal, info).isOkOr:
      return err(ECacheError)

  ok rawBals.len

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template balsDownload*(
    buddy: SnapPeerRef;                             # Snap peer
    minBn: BlockNumber;
    nBals: int;
    info: static[string];                           # Log message prefix
      ): auto =
  ## Async/template
  ##
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:
    # Check arguments for sanity
    let peer {.inject,used.} = $buddy.peer          # logging only
    verifyArgs(minBn, nBals, peer, info).isOkOr:
      bodyRc = typeof(bodyRc).err(EArgumentError)
      break body

    let q = buddy.getReqEnv(minBn, nBals, info).valueOr:
      debug info & ": Error assembling BAL request", peer, `error`=error
      bodyRc = typeof(bodyRc).err(error)            # no headers available
      break body

    # Fetch block hashes, check them and store on cache DB
    var fromInx = 0
    while fromInx < q.hdrs.len:
      let resp = buddy.fetchBlockAccessLists(q.balReq, fromInx).valueOr:
        bodyRc = typeof(bodyRc).err(error)
        trace info & ": Fetch error", fromInx=fromInx, `error`=error
        break body
      if resp.bal.len == 0:
        trace info & ": Fetch empty resopnse", fromInx=fromInx
        bodyRc = typeof(bodyRc).ok()
        break body

      trace info & ": Fetched BALS", fromInx=fromInx,
        fromNumber=q.hdrs[fromInx].number, nResp=resp.bal.len

      # Verify BALs and store on cache DB.
      let nProcessed = buddy.storeBals(resp.bal, q.hdrs, fromInx, info).valueOr:
        if error == EValidationError:
          # Mark remote peer unusable (if eth peer)
          buddy.ctx.pool.failedEthBalId.put(resp.peerID, zeroHash32)
          trace info & ": Validation error", peerID=resp.peerID.toHex,
            fromInx=fromInx, nResp=resp.bal.len, `error`=error
        bodyRc = typeof(bodyRc).err(error)
        break body
      if nProcessed == 0:
        bodyRc = typeof(bodyRc).ok()
        break body

      trace info & ": Verified & stored BALS", fromInx=fromInx,
        nProcessed=nProcessed, fromNumber=q.hdrs[fromInx].number,
        nResp=resp.bal.len

      fromInx += nProcessed
      # End `while ..`

    bodyRc = typeof(bodyRc).ok()

  bodyRc

template balsDownloadAppend*(
    buddy: SnapPeerRef;                             # Snap peer
    info: static[string];                           # Log message prefix
    nBalsMax = nProcBalDefaultBatchMax;             # Max session size
    nChunk = nProcBalDefaultChunk;                  # Process by data chunks
      ): auto =
  ## Async/template
  ##
  var bodyRc = Result[int,ErrorType].err(EGeneric)
  block body:
    let
      db = buddy.ctx.pool.cacheDB
      topHdrBn = db.lastHeaderNumber(info).valueOr: # get last header stored
        BlockNumber(0)
      topBalBn = db.lastBalNumber(info).valueOr:    # from last BAL stored
        let w = db.getAccMissingIntv(info).valueOr: # try last flat state
          bodyRc = typeof(bodyRc).err(ECacheError)
          break body
        w.number                                    # use this one as default

    if topHdrBn <= topBalBn:                        # sanity check
      bodyRc = typeof(bodyRc).err(EHeadersMissing)  # need more headers
      break body

    # Download and save blocks
    let
      maxBn = min(topBalBn + nBalsMax.uint, topHdrBn)
      firstBalBn = topBalBn + 1                    # first BAL to fetch
    var
      minBn = firstBalBn
    while minBn <= maxBn:
      let nBals = min(nChunk, (maxBn - minBn + 1).int)
      buddy.balsDownload(minBn, nBals, info).isOkOr:
        bodyRc = typeof(bodyRc).err(error)
        break body
      let balNum = db.lastBalNumber(info).valueOr:  # get latest BAL
        bodyRc = typeof(bodyRc).err(ECacheError)
        break body
      trace info & ": Processed BALs", nProcessed=(balNum - minBn)
      if balNum == minBn:                           # no progress
        bodyRc = typeof(bodyRc).ok((minBn - firstBalBn).int)
        break body
      minBn = balNum

    bodyRc = typeof(bodyRc).ok((maxBn - topBalBn).int)

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
