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
  ../../[helpers, mpt, worker_desc]

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
    nEmptyStoRange: int
    nStoSlot: int
    nContrCode: int
    nCodeBlob: int
    nMissCode: int

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

func isFullRange(itrs: ItemKeyRangeSet): bool =
  # Defensive encoding of a full range check. Solely testing `total; == 0`
  # leaves room for the case that the range is empty which is an illegal
  # situation but it can handled with savely.
  itrs.total == 0 and                              # => 0 or 2^256
  itrs.chunks == 1                                 # => one intv => full MPT

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getAccStats(
    db: CacheDbRef;
    info: static[string];
      ): (BlockNumber,float,int) =
  let stats = db.getAccMissingIntv(info).valueOr:
    return (0,-1f,-1)
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
          error info & ": Error dirtyStorage ust be set for partial sub-MPT",
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

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc statsStateLog*(
    ctx: SnapCtxRef;
    info: static[string];
    logNoise = LogNoise.smart;
      ) =
  ## Collect statistics
  const
    info2 = info & ": Download state stats"
  let
    start = Moment.now()
    db = ctx.pool.cacheDB
    (number, accMissRngPc, nAccMissRngChunk) = db.getAccStats info
    nFlatSlots = db.nFlatSlots info

  case logNoise:
  of minimal:
    let stats = db.statsWalk(info, shallowCheck=true).valueOr:
      chronicles.info info & ": Error collecting stats"
      return

    debug info2, number, accMissRngPC=accMissRngPc.pcStr, nAccMissRngChunk,
      nAcc = stats.nAcc,

      nStoMpt = stats.nStoSubMpt,
      nFullStoMpt = stats.nEmptyStoRange,
      nPartStoMpt = stats.nPartStoRange,
      nEmptyStoMpt = stats.nFullStoRange,
      nStoSlot = nFlatSlots,

      nContrCodes = stats.nContrCode,
      nCodeBlob = (stats.nContrCode - stats.nDirtyCode),
      nMissBlob = stats.nDirtyCode,

      ela=(Moment.now() - start).toStr

  of smart, full:
    let
      stats = db.statsWalk(info, shallowCheck=false).valueOr:
        chronicles.info info & ": Error collecting stats"
        return

      (nEmptyStoMpt, nPartStoMpt) = db.nMissPartStoRanges info
      nStoSlot = stats.nStoSlot

      nStoMpt = stats.nStoSubMpt
      nDirtyStoMpt = stats.nDirtyStorage

      nFullStoRange = stats.nFullStoRange
      nPartStoRange = stats.nPartStoRange
      nEmptyStoRange = stats.nEmptyStoRange

      nFlatBlob = db.nFlatBlobs info
      nFlatMissBlob = db.nFlatMissBlobs info
      nContrCode = stats.nContrCode
      nCodeBlob = stats.nCodeBlob
      nMissBlob = stats.nMissCode

    case logNoise:
    of smart:
      if nEmptyStoMpt + nPartStoMpt != nDirtyStoMpt:
        chronicles.info info & ": Storage sub-MPT counts do not add up",
          nEmptyStoMpt, nPartStoMpt, nDirtyStoMpt

      if nFullStoRange + nPartStoRange + nEmptyStoRange != nStoMpt:
        chronicles.info info & ": Storage range sub-MPT counts do not add up",
          nFullStoRange, nPartStoRange, nEmptyStoRange, nStoMpt

      if nPartStoRange != nPartStoMpt:
        chronicles.info info & ": Partial storage sub-MPT counts do not match",
          nPartStoMpt, nPartStoRange

      if nFullStoRange != nEmptyStoMpt:
        chronicles.info info & ": Empty storage sub-MPT counts do not match",
          nFullStoRange, nEmptyStoMpt

      if nFlatSlots != nStoSlot:
        chronicles.info info & ": Storage slot counts do not match",
          nFlatSlots, nStoSlot

      if nFlatBlob != nCodeBlob:
        chronicles.info info & ":  Contract code counts counts do not add up",
          nFlatBlob, nCodeBlob

      if nFlatMissBlob != nMissBlob:
        chronicles.info info & ":  Missing code counts counts do not add up",
          nFlatMissBlob, nMissBlob

      debug info2, number, accMissRngPC=accMissRngPc.pcStr, nAccMissRngChunk,
        nAcc=stats.nAcc,

        nStoMpt, nFullStoMpt=nEmptyStoRange, nPartStoMpt, nEmptyStoMpt,
        nStoSlot,

        nContrCode, nCodeBlob, nMissBlob,
        ela=(Moment.now() - start).toStr

    else:
      debug info2, number, accMissRngPC=accMissRngPc.pcStr, nAccMissRngChunk,
        nAcc=stats.nAcc,

        nStoMpt, nPartStoMpt, nEmptyStoMpt, nStoSlot,
        nEmptyStoMpt, nPartStoMpt, nFullStoRange, nPartStoRange, nEmptyStoRange,

        nContrCode, nCodeBlob, nMissBlob,
        nFlatBlob, nFlatMissBlob,

        ela=(Moment.now() - start).toStr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
