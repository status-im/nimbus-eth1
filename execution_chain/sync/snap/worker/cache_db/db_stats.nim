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
  pkg/[chronicles, chronos, stew/interval_set],
  ../../../../networking/[p2p, peer_pool],
  ../[helpers, worker_desc],
  ./[db_desc, db_flat, db_flat_simple]

logScope:
  topics = "snap sync"

type
  LogNoise* = enum
    minimal
    smart
    full

  FlatStatsWalk = tuple
    nAcc: int
    nDirtyCode: int
    nDirtyStorage: int
    nStoSubMpt: int
    nPartStoRange: int
    nFullStoRange: int
    nLockStoRange: int
    nEmptyStoRange: int
    nStoSlot: int
    nContrCode: int
    nCodeBlob: int
    nLockCode: int
    nMissCode: int

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func isFullRange(itrs: ItemKeyRangeSet): bool =
  itrs.total == 0 and                               # => 0 or 2^256
  itrs.chunks == 1                                  # => one intv => full MPT

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getAccStats(
    ctx: SnapCtxRef;
    info: static[string];
      ): (BlockNumber,float,int) =
  let stats = ctx.pool.cacheDB.getAccMissingIntv(info).valueOr:
    return (0,-1f,-1)
  if ctx.accUnproc.synced:
    return (stats.number, ctx.accUnproc.totalRatio, ctx.accUnproc.chunks())
  (stats.number, stats.ranges.total().per256(),stats.ranges.chunks())

proc nMissPartStoRanges(db: CacheDbRef, info: static[string]): (int,int) =
  for w in db.walkStoMissingIntv():
    if 0 < w.error.len:
      error info & ": Error walking flat storage ranges", error=w.error
      return (-1,-1)
    if w.data.ranges.isFullRange():
      result[0].inc                                 # full rng => empty sub-MPT
    else:
      result[1].inc                                 # partial range

proc nFlatBlobs(db: CacheDbRef, info: static[string]): int =
  let n = db.nFlatCode(info).valueOr:
    return -1
  n.int

proc nFlatMissBlobs(db: CacheDbRef, info: static[string]): int =
  let n = db.nMissingBlob(info).valueOr:
    return -1
  n.int

proc nFlatSlots(db: CacheDbRef, info: static[string]): int =
  let n = db.nFlatSlot(info).valueOr:
    return -1
  n.int

proc statsWalk(
    db: CacheDbRef;
    info: static[string];
    shallowCheck = false;
      ): Opt[FlatStatsWalk] =
  var stats: FlatStatsWalk
  for w in db.walkFlatAcc():
    if 0 < w.error.len:
      error info & ": Error walking accounts", accPath=w.accPath.toStr,
        nAccSoFar=stats.nAcc, `error`=w.error
      return err()

    stats.nAcc.inc
    if w.data.dirtyCode:
      stats.nDirtyCode.inc
    if w.data.dirtyStorage:
      stats.nDirtyStorage.inc

    if w.data.account.codeHash != EMPTY_CODE_HASH:
      stats.nContrCode.inc

      if ?db.hasMissingBlob(w.accPath, info):
        stats.nMissCode.inc
        if not w.data.dirtyCode:
          error info & ": Error dirtyCode should be set for missing code",
            accPath=w.accPath.toStr
      elif ?db.hasCodeLock(w.accPath, info):
        stats.nLockCode.inc
        if not w.data.dirtyCode:
          error info & ": Error dirtyCode must be set for locked sub-MPT",
            accPath=w.accPath.toStr
      else:
        stats.nCodeBlob.inc
        if w.data.dirtyCode:
          if shallowCheck:
            error info & ": Error dirtyCode unexpected",
              accPath=w.accPath.toStr
          elif ?db.hasFlatCode(w.accPath, info):
            error info & ": Error dirtyCode set for exixting code",
              accPath=w.accPath.toStr
          else:
            error info & ": Error missing contract code on cache DB",
              accPath=w.accPath.toStr

    if w.data.account.storageRoot != EMPTY_ROOT_HASH:
      stats.nStoSubMpt.inc

      let rc = ?db.getStoMissingIntv(w.accPath, info)
      if rc.isOk:                                   # complete sub-MPT?
        if rc.value.ranges.isFullRange():
          stats.nFullStoRange.inc
        else:
          stats.nPartStoRange.inc
        if not w.data.dirtyStorage:
          error info & ": Error dirtyStorage must be set for partial sub-MPT",
            accPath=w.accPath.toStr
        elif ?db.hasStoLock(w.accPath, info):
          error info & ": Error partial sub-MPT must not be locked",
            accPath=w.accPath.toStr
      elif ?db.hasStoLock(w.accPath, info):
        stats.nLockStoRange.inc
        if not w.data.dirtyStorage:
          error info & ": Error dirtyStorage must be set for locked sub-MPT",
            accPath=w.accPath.toStr
      else:
        stats.nEmptyStoRange.inc
        if w.data.dirtyStorage:
          if shallowCheck:
            error info & ": Error dirtyStorage unexpected",
              accPath=w.accPath.toStr
          elif ?db.hasFlatSlot(w.accPath, info):
            error info & ": Error dirtyStorage set for complete sub-MPT",
              accPath=w.accPath.toStr
          else:
            error info & ": Error missing storage slots on cache DB",
              accPath=w.accPath.toStr

      if not shallowCheck:
        var nSlots = 0
        for w in db.walkFlatSlot(w.accPath):
          if 0 < w.error.len:
            error info & ": Error walking storage slots (per account)",
              accPath=w.accPath.toStr, nSlotsSoFar=nSlots,
              slotKey=w.slotKey.toStr, `error`=w.error
            return err()
          nSlots.inc
        stats.nStoSlot += nSlots

  ok(stats)

# ----------------

proc statsStateImpl(
    ctx: SnapCtxRef;
    peer: Opt[Peer];
    logNoise: LogNoise;
    info: static[string];
      ) =
  ## Collect statistics
  const
    info2 = info & ": Download state stats"
  let
    peer = if peer.isSome(): $peer else: "n/a"
    start = Moment.now()
    db = ctx.pool.cacheDB
    (number, accMissRngPc, nAccMissRngChunk) = ctx.getAccStats info
    nFlatSlots = db.nFlatSlots info

  case logNoise:
  of minimal:
    let stats = db.statsWalk(info, shallowCheck=true).valueOr:
      chronicles.info info & ": Error collecting stats", peer
      return

    debug info2, peer, number,
      accMissRngPC=accMissRngPc.pcStr, nAccMissRngChunk,
      nAcc = stats.nAcc,

      nStoMpt = stats.nStoSubMpt,
      nLockStoRange = stats.nLockStoRange,
      nFullStoMpt = stats.nEmptyStoRange,
      nPartStoMpt = stats.nPartStoRange,
      nEmptyStoMpt = stats.nFullStoRange,
      nStoSlot = nFlatSlots,

      nContrCodes = stats.nContrCode,
      nCodeBlob = (stats.nContrCode - stats.nDirtyCode),
      nMissCode = stats.nDirtyCode,

      ela=(Moment.now() - start).toStr

  of smart, full:
    let
      stats = db.statsWalk(info, shallowCheck=false).valueOr:
        chronicles.info info & ": Error collecting stats", peer
        return

      (nEmptyStoMpt, nPartStoMpt) = db.nMissPartStoRanges info
      nStoSlot = stats.nStoSlot

      nStoMpt = stats.nStoSubMpt
      nDirtyStoMpt = stats.nDirtyStorage

      nLockStoRange = stats.nLockStoRange
      nFullStoRange = stats.nFullStoRange
      nPartStoRange = stats.nPartStoRange
      nEmptyStoRange = stats.nEmptyStoRange

      nFlatBlob = db.nFlatBlobs info
      nMissBlob = db.nFlatMissBlobs info

      nDirtyCode = stats.nDirtyCode
      nContrCode = stats.nContrCode
      nCodeBlob = stats.nCodeBlob
      nMissCode = stats.nMissCode
      nLockCode = stats.nLockCode

    case logNoise:
    of smart:
      if nLockStoRange + nEmptyStoMpt + nPartStoMpt != nDirtyStoMpt:
        error info & ": Storage sub-MPT counts do not add up", peer,
          number, nLockStoRange, nEmptyStoMpt, nPartStoMpt, nDirtyStoMpt

      if nLockStoRange+nFullStoRange+nPartStoRange+nEmptyStoRange != nStoMpt:
        error info & ": Storage range sub-MPT counts do not add up", peer,
          number, nLockStoRange, nFullStoRange, nPartStoRange,
          nEmptyStoRange, nStoMpt

      if nPartStoRange != nPartStoMpt:
        error info & ": Partial storage sub-MPT counts do not match", peer,
          number, nPartStoMpt, nPartStoRange

      if nFullStoRange != nEmptyStoMpt:
        error info & ": Empty storage sub-MPT counts do not match", peer,
          number, nFullStoRange, nEmptyStoMpt

      if nFlatSlots != nStoSlot:
        error info & ": Storage slot counts do not match", peer,
          number, nFlatSlots, nStoSlot

      # --------------

      if nCodeBlob != nFlatBlob:
        error info & ": Contract code counts do not match", peer,
          number, nCodeBlob, nFlatBlob

      if nMissCode != nMissBlob:
        error info & ": Missing code counts do not match", peer,
          number, nMissCode, nMissBlob

      if nLockCode + nMissCode != nDirtyCode:
        error info & ": Missing code counts do not add up", peer,
          number, nLockCode, nMissCode, nDirtyCode

      # --------------

      debug info2, peer, number,
        accMissRngPC=accMissRngPc.pcStr, nAccMissRngChunk,
        nAcc=stats.nAcc,

        nStoMpt, nLockStoMpt=nLockStoRange, nFullStoMpt=nEmptyStoRange,
        nPartStoMpt, nEmptyStoMpt, nStoSlot,

        nContrCode, nCodeBlob, nMissCode,
        ela=(Moment.now() - start).toStr

    else:
      debug info2, peer, number,
        accMissRngPC=accMissRngPc.pcStr, nAccMissRngChunk,
        nAcc=stats.nAcc,

        nStoMpt, nPartStoMpt, nEmptyStoMpt, nStoSlot,
        nEmptyStoMpt, nPartStoMpt, nFullStoRange, nPartStoRange, nEmptyStoRange,

        nContrCode, nCodeBlob, nMissCode,
        nFlatBlob, nMissBlob,

        ela=(Moment.now() - start).toStr

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc statsStateLog*(
    ctx: SnapCtxRef;
    info: static[string];
    logNoise = LogNoise.smart;
      ) =
  ctx.statsStateImpl(Opt.none(Peer), logNoise, info)

proc statsStateLog*(
    buddy: SnapPeerRef;
    info: static[string];
    logNoise = LogNoise.smart;
      ) =
  buddy.ctx.statsStateImpl(Opt.some(buddy.peer), logNoise, info)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
