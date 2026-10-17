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

template deleteAccount*(
    ctx: SnapCtxRef;
    accPath: Hash32;
    timer: TimerDataRef;
    info: static[string];
      ): auto =
  var bodyRc = Opt[void].err()
  block body:
    let
      adb = ctx.pool.cacheDB
      accPt = accPath.to(ItemKey)

    if not ctx.accUnproc.synced:                    # not on in-memeory cache?
      var accState = adb.getAccMissingIntv(info).valueOr:
        break body                                  # -> failed
      discard accState.ranges.merge(accPt, accPt)   # update bookkeeping
      adb.putAccMissingIntv(accState, info).isOkOr: # update on cache DB
        break body                                  # -> failed
    elif ctx.accUnproc.borrowed.chunks == 0:        # clean accounts registry?
      discard ctx.accUnproc.unprocessed.merge(accPt, accPt)
    else:
      error info & ": Cannot update dirty unprocessed ranges"
      break body                                    # failed

    adb.delFlatAcc(accPath, info).isOkOr:           # remove account record
      break body                                    # -> failed
    adb.delStoMissingIntv(accPath, info).isOkOr:    # delete storage accounting
      break body                                    # -> failed
    adb.delStoLock(accPath, info).isOkOr:           # delete storage lock
      break body                                    # -> failed
    adb.delMissingBlob(accPath, info).isOkOr:       # delete code accounting
      break body                                    # -> failed
    adb.delCodeLock(accPath, info).isOkOr:          # delete code lock
      break body                                    # -> failed
    adb.delFlatCode(accPath, info).isOkOr:          # delete contract code
      break body                                    # -> failed

    for slotKey in adb.walkFlatSlotKey(accPath):    # delete all slots
      adb.delFlatSlot(accPath, slotKey, info).isOkOr:
        break body                                  # -> failed
      timer.yieldThread()

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc

func isFullRange*(itrs: ItemKeyRangeSet): bool =
  # Defensive encoding of a full range check. Solely testing `total; == 0`
  # leaves room for the case that the range is empty which is an illegal
  # situation but it can handled with savely.
  itrs.total == 0 and                               # => 0 or 2^256
  itrs.chunks == 1                                  # => one intv => full MPT

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
