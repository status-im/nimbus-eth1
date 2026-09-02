# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Variety of cache DB wrappers with `Opt[]` return codes and error
## logging.

{.push raises: [].}

import
  pkg/[chronicles, eth/common, stew/interval_set],
  ../../[helpers, worker_desc],
  ./[cache_desc, cache_flat]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template failedToFetch(info, what: static[string]): auto =
  info & ": Failed to fetch " & what & " from cache"

template failedUpdating(info, what: static[string]): auto =
  info & ": Failed updaing " & what & " on cache"

template failedDeleting(info, what: static[string]): auto =
  info & ": Failed deleting " & what & " on cache"

template failedRangeUpd(info, what: static[string]): auto =
  info & ": Failed updaing " & what & " ranges"

# ------------------------------------------------------------------------------
# Public cache DB wrappers
# ------------------------------------------------------------------------------

proc hasAccMissingIntv*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[bool] =
  let data = db.getAccMissingIntv.valueOr:
    error info.failedToFetch "missing account ranges", `error`=error
    return err()
  if data.isNone():
    return ok(false)
  ok(0 < data.value.ranges.chunks)

proc getAccMissingIntv*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[CacheAccMissingIntvData] =
  var data = db.getAccMissingIntv.valueOr:
    error info.failedToFetch "missing account ranges", `error`=error
    return err()
  if data.isNone():
    # This record must always exist
    error info & ": Missing account ranges not on cache DB"
    return err()
  move data

proc putAccMissingIntv*(
    db: CacheDbRef;
    number: BlockNumber;
    ranges: ItemKeyRangeSet;
    info: static[string];
      ): Opt[void] =
  db.putAccMissingIntv(number, ranges).isOkOr:
    error info.failedRangeUpd "missing account ranges", `error`=error
    return err()
  ok()

proc putAccMissingIntv*(
    db: CacheDbRef;
    data: CacheAccMissingIntvData;
    info: static[string];
      ): Opt[void] =
  db.putAccMissingIntv(data.number, data.ranges).isOkOr:
    error info.failedRangeUpd "missing account ranges", `error`=error
    return err()
  ok()

proc updAccMissingIntv*(
    db: CacheDbRef;
    number: BlockNumber;
    info: static[string];
      ): Opt[void] =
  db.updAccMissingIntv(number).isOkOr:
    error info.failedRangeUpd "state root for accounts", number, `error`=error
    return err()
  ok()


proc getFlatAcc*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[CacheFlatAccData] =
  db.getFlatAcc(accPath).valueOr:
    error info.failedToFetch "account", accPath=accPath.toStr, `error`=error
    return err()

proc putFlatAcc*(
    db: CacheDbRef;
    accPath: Hash32;
    data: CacheFlatAccData;
    info: static[string];
      ): Opt[void] =
  db.putFlatAcc(accPath, data).isOkOr:
    error info.failedUpdating "account", accPath=accPath.toStr,
      `error`=error
    return err()
  ok()

proc putFlatAcc*(
  db: CacheDbRef;
  accPath: Hash32;
  dirtyStorage: bool;
  dirtyCode: bool;
  account: Account;
   info: static[string];
    ): Opt[void] =
  db.putFlatAcc(accPath, dirtyStorage, dirtyCode, account).isOkOr:
    error info.failedUpdating "account", accPath=accPath.toStr,
      dirtyStorage, dirtyCode, `error`=error
    return err()
  ok()

proc putFlatAcc*(
    db: CacheDbRef;
    accPath: Hash32;
    dirtyStorage: bool;
    dirtyCode: bool;
    payload: openArray[byte];
    info: static[string];
      ): Opt[void] =
  db.putFlatAcc(accPath, dirtyStorage, dirtyCode, payload).isOkOr:
    error info.failedUpdating "account", accPath=accPath.toStr,
      dirtyStorage, dirtyCode, `error`=error
    return err()
  ok()

proc delFlatAcc*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  db.delFlatAcc(accPath).isOkOr:
    error info.failedDeleting "account", accPath=accPath.toStr, `error`=error
    return err()
  ok()

proc nFlatAcc*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[uint] =
  var nAccounts = 0u
  for w in db.walkFlatAcc():
    if 0 < w.error.len:
      error info & ": Error walking accounts on cache DB",
        accPath=w.accPath.toStr, error=w.error
      return err()
    nAccounts.inc
  ok(move nAccounts)

# -----------

proc hasStoMissingIntv*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[bool] =
  var data = db.hasStoMissingIntv().valueOr:
    error info.failedToFetch "missing storage slots ranges", `error`=error
    return err()
  ok(move data)

proc getStoMissingIntv*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[Opt[CacheStoMissingIntvData]] =
  var data = db.getStoMissingIntv(accPath).valueOr:
    error info.failedToFetch "missing storage slot ranges",
      accPath=accPath.toStr, `error`=error
    return err()
  if data.isNone():
    # Storage slots missing intv records need not exixts. This differs from
    # requirement of missing intv record for accounts (which must exisit.)
    return Opt.some(Opt.none(CacheStoMissingIntvData))
  Opt.some(move data)

proc putStoMissingIntv*(
    db: CacheDbRef;
    accPath: Hash32;
    ranges: ItemKeyRangeSet;
    info: static[string];
      ): Opt[void] =
  db.putStoMissingIntv(accPath, ranges).isOkOr:
    error info.failedRangeUpd "missing storage slot ranges",
      accPath=accPath.toStr, `error`=error
    return err()
  ok()

proc putStoMissingIntv*(
    db: CacheDbRef;
    accPath: Hash32;
    data: CacheStoMissingIntvData;
    info: static[string];
      ): Opt[void] =
  db.putStoMissingIntv(accPath, data.ranges).isOkOr:
    error info.failedRangeUpd "missing storage slot ranges",
      accPath=accPath.toStr, `error`=error
    return err()
  ok()

proc delStoMissingIntv*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  db.delStoMissingIntv(accPath).isOkOr:
    error info.failedDeleting "missing storage slot ranges",
      accPath=accPath.toStr, `error`=error
    return err()
  ok()


proc hasFlatSlot*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[bool] =
  var data = db.hasFlatSlot(accPath).valueOr:
    error info.failedToFetch "any storage slot", accPath=accPath.toStr,
      `error`=error
    return err()
  ok(move data)

proc getFlatSlot*(
    db: CacheDbRef;
    accPath: Hash32;
    slotKey: Hash32;
    info: static[string];
      ): Opt[UInt256] =
  db.getFlatSlot(accPath, slotKey).valueOr:
    error info.failedToFetch "storage slot", accPath=accPath.toStr,
      stoKey=slotKey.toStr, `error`=error
    return err()

proc putFlatSlot*(
    db: CacheDbRef;
    accPath: Hash32;
    slotKey: Hash32;
    data: UInt256;
    info: static[string];
      ): Opt[void] =
  db.putFlatSlot(accPath, slotKey, data).isOkOr:
    error info.failedUpdating "storage slot", accPath=accPath.toStr,
      slotKey=slotKey.toStr, stoValue=data.flStr, `error`=error
    return err()
  ok()

proc putFlatSlot*(
    db: CacheDbRef;
    accPath: Hash32;
    slotKey: Hash32;
    payload: openArray[byte];
    info: static[string];
      ): Opt[void] =
  db.putFlatSlot(accPath, slotKey, payload).isOkOr:
    error info.failedUpdating "storage slot", accPath=accPath.toStr,
      slotKey=slotKey.toStr, payloadLen=payload.len, `error`=error
    return err()
  ok()

proc delFlatSlot*(
    db: CacheDbRef;
    accPath: Hash32;
    slotKey: Hash32;
    info: static[string];
      ): Opt[void] =
  db.delFlatSlot(accPath, slotKey).isOkOr:
    error info.failedDeleting "storage slot", accPath=accPath.toStr,
      stoKey=slotKey.toStr, `error`=error
    return err()
  ok()

proc delFlatSlot*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  db.delFlatSlot(accPath).isOkOr:
    error info.failedDeleting "storage sub-MPT", accPath=accPath.toStr,
      `error`=error
    return err()
  ok()

proc nFlatSlot*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[uint] =
  var nSlots = 0u
  for w in db.walkFlatSlot():
    if 0 < w.error.len:
      error info & ": Error walking accounts on cache DB",
        accPath=w.accPath.toStr, slotKey=w.slotKey.toStr, error=w.error
      return err()
    nSlots.inc
  ok(move nSlots)

# -----------

proc clearMissingIntv*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[void] =
  ## Deletes all missing interval records for accounts and storage
  ## sub-MPTs.
  db.clearMissingIntv().isOkOr:
    error info.failedDeleting "all accounting records", `error`=error
    return err()
  ok()

# -----------

proc hasMissingBlob*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[bool] =
  var data = db.hasMissingBlob().valueOr:
    error info.failedToFetch "missing code blobs", `error`=error
    return err()
  ok(move data)

proc hasMissingBlob*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[bool] =
  var data = db.hasMissingBlob(accPath).valueOr:
    error info.failedToFetch "missing code blobs", accPath=accPath.toStr,
      `error`=error
    return err()
  ok(move data)

proc putMissingBlob*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  db.putMissingBlob(accPath).isOkOr:
    error info.failedUpdating "missing code blob", accPath=accPath.toStr,
      `error`=error
    return err()
  ok()

proc delMissingBlob*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  db.delMissingBlob(accPath).isOkOr:
    error info.failedDeleting "missing code blob", accPath=accPath.toStr,
      `error`=error
    return err()
  ok()

proc nMissingBlob*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[uint] =
  var nCodes = 0u
  for _ in db.walkMissingBlob():
    nCodes.inc
  ok(move nCodes)


proc hasFlatCode*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[bool] =
  var data = db.hasFlatCode(accPath).valueOr:
    error info.failedToFetch "contract code", accPath=accPath.toStr,
      `error`=error
    return err()
  ok(move data)

proc getFlatCode*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[seq[byte]] =
  var data = db.getFlatCode(accPath).valueOr:
    error info.failedToFetch "contract code", accPath=accPath.toStr,
      `error`=error
    return err()
  ok(move data)

proc putFlatCode*(
    db: CacheDbRef;
    accPath: Hash32;
    data: openArray[byte];
    info: static[string];
      ): Opt[void] =
  db.putFlatCode(accPath, data).isOkOr:
    error info.failedUpdating "contract code", accPath=accPath.toStr,
      nCode=data.len, `error`=error
    return err()
  ok()

proc delFlatCode*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  db.delFlatCode(accPath).isOkOr:
    error info.failedDeleting "contract code", accPath=accPath.toStr,
      `error`=error
    return err()
  ok()

proc nFlatCode*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[uint] =
  var nCodes = 0u
  for _ in db.walkFlatCode():
    nCodes.inc
  ok(move nCodes)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
