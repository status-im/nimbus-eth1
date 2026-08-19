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
  pkg/[chronicles, chronos],
  ../../[helpers, mpt, worker_desc]

logScope:
  topics = "snap sync"

type
  FlatStatsWalk* = tuple
    accLeaf: uint
    accCode: uint
    dirtyCode: uint
    stoTrie: uint
    dirtyStore: uint
    stoLeaf: uint
    ela: Duration

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc statsWalk*(db: CacheDbRef, info: static[string]): Opt[FlatStatsWalk] =
  let start = Moment.now()

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

  stats.ela = Moment.now() - start
  ok(stats)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
