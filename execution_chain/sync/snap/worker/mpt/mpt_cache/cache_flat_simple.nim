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
  ../../[helpers, state_db, worker_desc],
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
    error info.failedToFetch "missing accounts state", `error`=error
    return err()
  if data.isNone():
    error info & ": Missing accounts state, not on cache DB"
    return err()
  ok(0 < data.value.ranges.chunks)

proc getAccMissingIntv*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[CacheAccMissingIntvData] =
  var data = db.getAccMissingIntv.valueOr:
    error info.failedToFetch "missing accounts state", `error`=error
    return err()
  if data.isNone():
    # This record must always exist
    error info & ": Missing accounts state, not on cache DB"
    return err()
  move data

proc putAccMissingIntv*(
    db: CacheDbRef;
    number: BlockNumber;
    ranges: ItemKeyRangeSet;
    info: static[string];
      ): Opt[void] =
  db.putAccMissingIntv(number, ranges).isOkOr:
    error info.failedRangeUpd "storage slot", `error`=error
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
      ): Opt[Opt[CacheFlatAccData]] =
  var data = db.getFlatAcc(accPath).valueOr:
    error info.failedToFetch "account", accPath=accPath.toStr, `error`=error
    return err()
  ok(move data)

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
    payload: openArray[byte];
    info: static[string];
      ): Opt[void] =
  db.putFlatAcc(accPath, dirtyStorage, dirtyCode, payload).isOkOr:
    error info.failedUpdating "account", accPath=accPath.toStr,
      accPath=accPath.toStr, dirtyStorage, dirtyCode, `error`=error
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
    accPath: Hash32;
    info: static[string];
      ): Opt[bool] =
  let data = db.getStoMissingIntv(accPath).valueOr:
    error info.failedToFetch "missing storage slots", `error`=error
    return err()
  if data.isNone():
    # Storage slots missing intv records need not exixts, contrary to the
    # missing intv record for accounts.
    return ok(false)
  ok(0 < data.value.ranges.chunks)

proc getStoMissingIntv*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[Opt[CacheStoMissingIntvData]] =
  var data = db.getStoMissingIntv(accPath).valueOr:
    error info.failedToFetch "missing storage slots", `error`=error
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
    error info.failedRangeUpd "storage slot", `error`=error
    return err()
  ok()

proc getFlatSlot*(
    db: CacheDbRef;
    accPath: Hash32;
    slotKey: Hash32;
    info: static[string];
      ): Opt[Opt[UInt256]] =
  var data = db.getFlatSlot(accPath, slotKey).valueOr:
    error info.failedToFetch "storage slot", accPath=accPath.toStr,
      stoKey=slotKey.toStr, `error`=error
    return err()
  ok(move data)

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

# -----------

proc hasMissingBlob*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[bool] =
  var data = db.hasMissingBlob(accPath).valueOr:
    error info.failedToFetch "missing contract code", accPath=accPath.toStr,
      `error`=error
    return err()
  ok(move data)

proc putMissingBlob*(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  db.putMissingBlob(accPath).isOkOr:
    error info.failedUpdating "missing contract code", accPath=accPath.toStr,
      `error`=error
    return err()
  ok()


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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
