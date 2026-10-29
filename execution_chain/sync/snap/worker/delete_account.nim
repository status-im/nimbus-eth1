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
  ./[cache_db, worker_desc]

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc deleteAccount*(
    ctx: SnapCtxRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  ## Delete account including sub-entries.
  ##
  let
    adb = ctx.pool.cacheDB
    accPt = accPath.to(ItemKey)

  if not ctx.accUnproc.synced:                      # not on in-memeory cache?
    var accState = ?adb.getAccMissingIntv(info)
    discard accState.ranges.merge(accPt, accPt)     # update bookkeeping
    ?adb.putAccMissingIntv(accState, info)          # update on cache DB
  elif ctx.accUnproc.borrowed.chunks == 0:          # clean accounts registry?
    discard ctx.accUnproc.unprocessed.merge(accPt, accPt)
  else:
    error info & ": Cannot update dirty unprocessed ranges",
      nBorrowedChunks=ctx.accUnproc.borrowed.chunks
    return err()                                    # failed

  ?adb.delFlatAcc(accPath, info)                    # remove account record
  ?adb.delStoMissingIntv(accPath, info)             # delete storage accounting
  ?adb.delStoLock(accPath, info)                    # delete storage lock
  ?adb.delMissingBlob(accPath, info)                # delete code accounting
  ?adb.delCodeLock(accPath, info)                   # delete code lock
  ?adb.delFlatCode(accPath, info)                   # delete contract code
  ?adb.clearFlatSlot(accPath, info)                 # delete all account slots

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
