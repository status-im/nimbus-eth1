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
##   + col:       `cLeafIntv`
##   + key:       `Hash32`, zero for accounts, account path for storage slots
##   * root:      `Hash32`, state root or storage root
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
##   + key33: <col, acc-path, key>
##   + value: <slot>
##   where
##   + col:       `cFlatSlot`
##   + acc-path:  `Hash32`
##   + key:       `Hash32`,
##   + data:      `UInt32`
##

{.push raises: [].}

import
  pkg/[eth/common, results, stew/interval_set],
  ../../state_db,
  ./[cache_api33, cache_api65,
     cache_const, cache_desc, cache_r_cmd, cache_rlp]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hasAccLeafIntv*(db: MptAsmRef): BoolResult =
  let data = db.get33(cLeafIntv, zeroHash32).valueOr:
    return err(error)
  ok(0 < data.len)

proc hasStoLeafIntv*(db: MptAsmRef, accPath: Hash32): BoolResult =
  let data = db.get33(cLeafIntv, accPath).valueOr:
    return err(error)
  ok(0 < data.len)

proc getAccLeafInv*(db: MptAsmRef): OptLeafInvResult =
  let data = db.get33(cLeafIntv, zeroHash32).valueOr:
    return err(error)
  if data.len == 0:
    return ok Opt.none(DecodedLeafIntv)
  var res = data.decodeLeafInv().valueOr:
    return err(error)
  ok Opt.some(move res)

proc getStoLeafInv*(db: MptAsmRef, accPath: Hash32): OptLeafInvResult =
  let data = db.get33(cLeafIntv, accPath).valueOr:
    return err(error)
  if data.len == 0:
    return ok Opt.none(DecodedLeafIntv)
  var res = data.decodeLeafInv().valueOr:
    return err(error)
  ok Opt.some(move res)

proc putAccLeafInv*(
    db: MptAsmRef;
    root: StateRoot;
    ranges: ItemKeyRangeSet;
      ): PutResult =
  db.put33(cLeafIntv, zeroHash32, encodeLeafInv(Hash32 root, ranges))

proc putStoLeafInv*(
    db: MptAsmRef;
    accPath: Hash32;
    root: StoreRoot;
    ranges: ItemKeyRangeSet;
      ): PutResult =
  db.put33(cLeafIntv, accPath, encodeLeafInv(Hash32 root, ranges))

proc delStoLeafInv*(
    db: MptAsmRef,
    accPath: Hash32;
      ): DelResult =
  db.del33(cLeafIntv, accPath)

proc clearLeafInv*(db: MptAsmRef): DelResult =
  db.adb.rClear(cLeafIntv)

# -------------

proc hasFlatAcc*(db: MptAsmRef, path: Hash32): BoolResult =
  let data = db.get33(cFlatAcc, path).valueOr:
    return err(error)
  ok(0 < data.len)

proc getFlatAcc*(db: MptAsmRef, path: Hash32): OptFlatAccResult =
  let data = db.get33(cFlatAcc, path).valueOr:
    return err(error)
  if data.len == 0:
    return ok Opt.none(Account)
  var res = data.decodeFlatAcc().valueOr:
    return err(error)
  ok Opt.some(move res)

proc putFlatAcc*(db: MptAsmRef, path: Hash32, account: Account): PutResult =
  db.put33(cFlatAcc, path, encodeFlatAcc(account))

proc delFlatAcc*(db: MptAsmRef, path: Hash32): DelResult =
  db.del33(cFlatAcc, path)

proc clearFlatAcc*(db: MptAsmRef): DelResult =
  db.adb.rClear(cFlatAcc)

# -------------

proc hasFlatSlot*(db: MptAsmRef, accPath, key: Hash32): BoolResult =
  let data = db.get65(cFlatSlot, accPath, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getFlatSlot*(db: MptAsmRef, accPath, key: Hash32): OptFlatSlotResult =
  let data = db.get65(cFlatSlot, accPath, key).valueOr:
    return err(error)
  if data.len == 0:
    return ok Opt.none(UInt256)
  var res = data.decodeFlatSlot().valueOr:
    return err(error)
  ok Opt.some(move res)

proc putFlatSlot*(
    db: MptAsmRef;
    accPath: Hash32;
    key: Hash32;
    data: UInt256;
      ): PutResult =
  db.put65(cFlatSlot, accPath, key, encodeFlatSlot(data))

proc delFlatSlot*(db: MptAsmRef, accPath, key: Hash32): DelResult =
  db.del65(cFlatSlot, accPath, key)

proc clearFlatSlot*(db: MptAsmRef): DelResult =
  db.adb.rClear(cFlatSlot)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
