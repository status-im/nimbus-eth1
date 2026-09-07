# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  pkg/stew/interval_set,
  ../[cache_db, worker_desc]

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc deleteAccount*(
    ctx: SnapCtxRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  let
    adb = ctx.pool.cacheDB
    accPt = accPath.to(ItemKey)

  if ctx.accUnproc.synced:                          # have in-memeory cache?
    ctx.accUnproc.overCommit(accPt,accPt)           # update accounts registry
  else:
    var accState = ?adb.getAccMissingIntv(info)
    discard accState.ranges.merge(accPt, accPt)
    ?adb.putAccMissingIntv(accState, info)          # update bookkeeping

  ?adb.delFlatAcc(accPath, info)                    # remove account record
  ?adb.delStoMissingIntv(accPath, info)             # delete storage accounting
  ?adb.delStoLock(accPath, info)                    # delete storage lock
  ?adb.delFlatSlot(accPath, info)                   # delete all slots
  ?adb.delMissingBlob(accPath, info)                # delete code accounting
  ?adb.delCodeLock(accPath, info)                   # delete code lock
  ?adb.delFlatCode(accPath, info)                   # delete contract code
  ok()

func isFullRange*(itrs: ItemKeyRangeSet): bool =
  # Defensive encoding of a full range check. Solely testing `total; == 0`
  # leaves room for the case that the range is empty which is an illegal
  # situation but it can handled with savely.
  itrs.total == 0 and                               # => 0 or 2^256
  itrs.chunks == 1                                  # => one intv => full MPT

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
