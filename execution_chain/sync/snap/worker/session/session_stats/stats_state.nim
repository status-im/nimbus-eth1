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
    full

  FlatStatsWalk = tuple
    accLeaf: uint
    accCode: uint
    dirtyCode: uint
    dirtyFullStore: uint
    cleanFullStore: uint
    stoTrie: uint
    dirtyStore: uint
    stoLeaf: uint

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
    if w.data.ranges.total == 0 and                 # 0 mod 2^256 => 0 or 2^256
       w.data.ranges.chunks == 0:                   # empty => 0, full MPT
      result[0].inc                                 # zero range
    else:
      result[1].inc                                 # partial range

proc nCode(db: CacheDbRef, info: static[string]): int =
  let n = db.nFlatCode(info).valueOr:
    return -1
  n.int

proc nMissCode(db: CacheDbRef, info: static[string]): int =
  let n = db.nMissingBlob(info).valueOr:
    return -1
  n.int


proc statsWalk(db: CacheDbRef, info: static[string]): Opt[FlatStatsWalk] =
  var stats: FlatStatsWalk
  for w in db.walkFlatAcc():
    if 0 < w.error.len:
      error info & ": Error walking accounts", accPath=w.accPath.toStr,
        nAccSoFar=stats.accLeaf, `error`=w.error
      return err()

    stats.accLeaf.inc
    if w.data.dirtyCode:
      stats.dirtyCode.inc
    if w.data.account.codeHash != EMPTY_CODE_HASH:
      stats.accCode.inc

    if w.data.dirtyStorage:
      stats.dirtyStore.inc
    if w.data.account.storageRoot != EMPTY_ROOT_HASH:
      let stoState = (?db.getStoMissingIntv(w.accPath, info)).valueOr:
        error info & ": Error missing storage state", accPath=w.accPath.toStr
        return err()
      if stoState.ranges.total == 0 and             # 0 mod 2^256 => 0 or 2^256
       stoState.ranges.chunks == 0:                 # empty => 0, full MPT
        if w.data.dirtyStorage:
          stats.dirtyFullStore.inc
        else:
          stats.cleanFullStore.inc
      stats.stoTrie.inc
      var nSlots = 0u
      for w in db.walkFlatSlot(w.accPath):
        if 0 < w.error.len:
          error info & ": Error walking storage slots (per account)",
            accPath=w.accPath.toStr, nSlotsSoFar=nSlots,
            slotKey=w.slotKey.toStr, `error`=w.error
          return err()
        nSlots.inc
      stats.stoLeaf += nSlots

  var nSlots = 0u
  for w in db.walkFlatSlot():
    if 0 < w.error.len:
      error info & ": Error walking storage slots (globally)",
        accPath=w.accPath.toStr, nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr,
        `error`=w.error
      return err()
    nSlots.inc

  if nSlots != stats.stoLeaf:
    error info & ": Storage slots counts differ (globally vs per account)",
      nSlotsGlobally=nSlots, nSlotsPerAccount=stats.stoLeaf

  ok(stats)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc statsStateLog*(
    ctx: SnapCtxRef;
    info: static[string];
    logNoise = LogNoise.full;
      ) =
  ## Collect statistics
  const
    info = info & ": Accounts state stats"
  let
    start = Moment.now()
    db = ctx.pool.cacheDB
    stats = db.statsWalk(info).valueOr: FlatStatsWalk.default
    (number, accMissRngPc, nAccMissRngChunk) = db.getAccStats info
    nCleanStoMpt = (stats.stoTrie - stats.dirtyStore)
    nDirtyStoMpt = stats.dirtyStore
    nCleanCodes = (stats.accCode - stats.dirtyCode)
    nDirtyCodes = stats.dirtyCode

  case logNoise:
  of minimal:
    let
      ela = Moment.now() - start
    debug info, number, accMissRngPC=accMissRngPc.pcStr, nAccMissRngChunk,
      nAcc=stats.accLeaf, nStoSlots=stats.stoLeaf,
      nCleanStoMpt, nDirtyStoMpt, nCleanCodes, nDirtyCodes, ela=ela.toStr

  of full:
    let
      (nFullStoMpt, nPartStoMpt) = db.nMissPartStoRanges info
      nDirtyFullStoMpt = stats.dirtyFullStore
      nCleanFullStoMpt = stats.cleanFullStore
      nFullCode = db.nCode info
      nMissCode = db.nMissCode info
      ela = Moment.now() - start
    debug info, number, accMissRngPC=accMissRngPc.pcStr, nAccMissRngChunk,
      nAcc=stats.accLeaf, nStoSlots=stats.stoLeaf, nFullStoMpt, nPartStoMpt,
      nCleanStoMpt, nCleanFullStoMpt, nDirtyStoMpt, nDirtyFullStoMpt,
      nFullCode, nMissCode, nCleanCodes, nDirtyCodes,
      ela=ela.toStr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
