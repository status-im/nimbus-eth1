# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Flat leaf tables and range lists
## --------------------------------
##
## * Unprocessed leaf ranges
##   + key33: <col, key>
##   + value: <root, ranges>
##   where
##   + col:       `cMissingIntv`
##   + key:       `Hash32`, zero for accounts, account path for storage slots
##   * root:      `Hash32`, state root or storage root
##   * ranges:    `ItemKeyRangeSet`
##
## * Missing contract codes
##   + key33: <col, key>
##   + value: <1>
##   where
##   + col:       `cMissingBlob`
##   + key:       `Hash32`, code hash
##
## * Flat accounts list
##   + key33: <col, key>
##   + value: <account>
##   where
##   + col:       `cFlatAcc`
##   + key:       `Hash32`
##   + data:      `Account`
##
## * Flat storage slots list
##   + key33: <col, acc-path>
##   + value: <slot>
##   where
##   + col:       `cFlatSlot`
##   + acc-path:  `Hash32`
##   + data:      `UInt32`
##
## * Flat contract codes
##   + key33: <col, acc-path>
##   + value: <blob>
##   where
##   + col:       `cFlatCodet`
##   + acc-path:  `Hash32`
##   + data:      `seq[byte]`
##

{.push raises: [].}

import
  pkg/[eth/common, results, stew/interval_set],
  ../../state_db,
  ./[cache_api1, cache_api33, cache_api65,
     cache_const, cache_desc, cache_iter, cache_rlp]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hasAccMissingIntv*(db: CacheDbRef): BoolResult =
  let data = db.get1(cMissingIntv).valueOr:
    return err(error)
  ok(0 < data.len)

proc getAccMissingIntv*(db: CacheDbRef): OptAccMissingIntvResult =
  let data = db.get1(cMissingIntv).valueOr:
    return err(error)
  if data.len == 0:
    return ok Opt.none(CacheAccMissingIntvData)
  var res = data.decodeAccMissingIntvData().valueOr:
    return err(error)
  ok Opt.some(move res)

proc putAccMissingIntv*(
    db: CacheDbRef;
    number: BlockNumber;
    ranges: ItemKeyRangeSet;
      ): PutResult =
  db.put1(cMissingIntv, encodeAccMissingIntvData(number, ranges))

proc updAccMissingIntv*(
    db: CacheDbRef;
    number: BlockNumber;
      ): PutResult =
  let data = db.get1(cMissingIntv).valueOr:
    return err(error)
  if data.len == 0:
    return err("missing record cannot be updated")
  let res = data.decodeAccMissingIntvData().valueOr:
    return err(error)
  db.put1(cMissingIntv, encodeAccMissingIntvData(number, res.ranges))

proc addAccMissingIntv*(
    db: CacheDbRef;
    number: BlockNumber;
    iv: ItemKeyRange;
      ): PutResult =
  let data = db.get1(cMissingIntv).valueOr:
    return err(error)
  var res: CacheAccMissingIntvData
  if data.len == 0:
    res.ranges = ItemKeyRangeSet.init()
  else:
    res = data.decodeAccMissingIntvData().valueOr:
      return err(error)
  discard res.ranges.merge iv
  db.put1(cMissingIntv, encodeAccMissingIntvData(number, res.ranges))

proc delAccMissingIntv*(
    db: CacheDbRef,
      ): DelResult =
  db.del1(cMissingIntv)

# -------------

proc hasStoMissingIntv*(db: CacheDbRef, accPath: Hash32): BoolResult =
  let data = db.get33(cMissingIntv, accPath).valueOr:
    return err(error)
  ok(0 < data.len)

proc getStoMissingIntv*(
    db: CacheDbRef;
    accPath: Hash32;
      ): OptStoMissingIntvResult =
  let data = db.get33(cMissingIntv, accPath).valueOr:
    return err(error)
  if data.len == 0:
    return ok Opt.none(CacheStoMissingIntvData)
  var res = data.decodeStoMissingIntvData().valueOr:
    return err(error)
  ok Opt.some(move res)

proc putStoMissingIntv*(
    db: CacheDbRef;
    accPath: Hash32;
    ranges: ItemKeyRangeSet;
      ): PutResult =
  db.put33(cMissingIntv, accPath, encodeStoMissingIntvData ranges)

proc addStoMissingIntv*(
    db: CacheDbRef;
    accPath: Hash32;
    iv: ItemKeyRange;
      ): PutResult =
  let data = db.get33(cMissingIntv, accPath).valueOr:
    return err(error)
  var res: CacheStoMissingIntvData
  if data.len == 0:
    res.ranges = ItemKeyRangeSet.init()
  else:
    res = data.decodeStoMissingIntvData().valueOr:
      return err(error)
  discard res.ranges.merge iv
  db.put33(cMissingIntv, accPath, encodeStoMissingIntvData res.ranges)

proc delStoMissingIntv*(
    db: CacheDbRef,
    accPath: Hash32;
      ): DelResult =
  db.del33(cMissingIntv, accPath)

iterator walkStoMissingIntv*(db: CacheDbRef): WalkStoMissingIntvData =
  for (key,value) in db.adb.colWalk33 key33(cMissingIntv, zeroHash32):
    let w = value.decodeStoMissingIntvData().valueOr:
      var oops: WalkStoMissingIntvData
      oops.accPath = key
      oops.error = error
      yield oops
      continue
    yield (key, w, "")

# -------------

proc clearMissingIntv*(db: CacheDbRef): DelResult =
  db.clr1 cMissingIntv

# -------------

proc hasMissingBlob*(db: CacheDbRef, accPath: Hash32): BoolResult =
  let data = db.get33(cMissingBlob, accPath).valueOr:
    return err(error)
  ok(0 < data.len)

proc putMissingBlob*(db: CacheDbRef, accPath: Hash32): PutResult =
  db.put33(cMissingBlob, accPath, [byte 1])

proc delMissingBlob*(db: CacheDbRef, accPath: Hash32): DelResult =
  db.del33(cMissingBlob, accPath)

proc clearMissingBlob*(db: CacheDbRef): DelResult =
  db.clr1 cMissingBlob

iterator walkMissingBlob*(db: CacheDbRef): Hash32 =
  for (key, _) in db.adb.colWalk33 [byte cMissingBlob]:
    yield key

# =============

proc hasFlatAcc*(db: CacheDbRef, accPath: Hash32): BoolResult =
  let data = db.get33(cFlatAccount, accPath).valueOr:
    return err(error)
  ok(0 < data.len)

proc getFlatAcc*(db: CacheDbRef, accPath: Hash32): OptFlatAccResult =
  let data = db.get33(cFlatAccount, accPath).valueOr:
    return err(error)
  if data.len == 0:
    return ok Opt.none(Account)
  var res = data.decodeFlatAccData().valueOr:
    return err(error)
  ok Opt.some(move res)

proc putFlatAcc*(db: CacheDbRef, accPath: Hash32, account: Account): PutResult =
  db.put33(cFlatAccount, accPath, encodeFlatAccData(account))

proc putFlatAcc*(
    db: CacheDbRef;
    accPath: Hash32;
    data: openArray[byte];
      ): PutResult =
  db.put33(cFlatAccount, accPath, data)

proc delFlatAcc*(db: CacheDbRef, accPath: Hash32): DelResult =
  db.del33(cFlatAccount, accPath)

proc clearFlatAcc*(db: CacheDbRef): DelResult =
  db.clr1 cFlatAccount

iterator walkFlatAcc*(db: CacheDbRef): WalkFlatAccData =
  for (key,value) in db.adb.colWalk33 key33(cFlatAccount):
    let w = value.decodeFlatAccData().valueOr:
      var oops: WalkFlatAccData
      oops.accPath = key
      oops.error = error
      yield oops
      continue
    yield (key, w, "")

# -------------

proc hasFlatSlot*(db: CacheDbRef, accPath, slotKey: Hash32): BoolResult =
  let data = db.get65(cFlatSlot, accPath, slotKey).valueOr:
    return err(error)
  ok(0 < data.len)

proc getFlatSlot*(db: CacheDbRef, accPath, slotKey: Hash32): OptFlatSlotResult =
  let data = db.get65(cFlatSlot, accPath, slotKey).valueOr:
    return err(error)
  if data.len == 0:
    return ok Opt.none(UInt256)
  var res = data.decodeFlatSlotData().valueOr:
    return err(error)
  ok Opt.some(move res)

proc putFlatSlot*(
    db: CacheDbRef;
    accPath: Hash32;
    slotKey: Hash32;
    data: UInt256;
      ): PutResult =
  db.put65(cFlatSlot, accPath, slotKey, encodeFlatSlotData(data))

proc putFlatSlot*(
    db: CacheDbRef;
    accPath: Hash32;
    slotKey: Hash32;
    data: openArray[byte];
      ): PutResult =
  db.put65(cFlatSlot, accPath, slotKey, data)

proc delFlatSlot*(db: CacheDbRef, accPath, slotKey: Hash32): DelResult =
  db.del65(cFlatSlot, accPath, slotKey)

proc clearFlatSlot*(db: CacheDbRef): DelResult =
  db.clr1 cFlatSlot

iterator walkFlatSlot*(db: CacheDbRef): WalkFlatSlotData =
  for (key1,key2,value) in db.adb.colWalk65 key65(cFlatSlot):
    let w = value.decodeFlatSlotData().valueOr:
      var oops: WalkFlatSlotData
      oops.accPath = key1
      oops.slotKey = key2
      oops.error = error
      yield oops
      continue
    yield (key1, key2, w, "")

# -------------

proc hasFlatCode*(db: CacheDbRef; accPath: Hash32): BoolResult =
  let data = db.get33(cFlatCode, accPath).valueOr:
    return err(error)
  ok(0 < data.len)

proc getFlatCode*(db: CacheDbRef; accPath: Hash32): BlobResult =
  var data = db.get33(cFlatCode, accPath).valueOr:
    return err(error)
  ok(move data)

proc putFlatCode*(
    db: CacheDbRef;
    accPath: Hash32;
    data: openArray[byte];
      ): PutResult =
  db.put33(cFlatCode, accPath, data)

proc delFlatCode*(db: CacheDbRef, accPath: Hash32): DelResult =
  db.del33(cFlatCode, accPath)

proc clearFlatCode*(db: CacheDbRef): DelResult =
  db.clr1 cFlatCode

iterator walkFlatCode*(db: CacheDbRef): KvPair =
  for (key,value) in db.adb.colWalkAtLeast1 @[byte cFlatCode]:
    yield (key,value)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
