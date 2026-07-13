# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Reference headers and block access lists
## ----------------------------------------
##
## * headers:
##   + key9: <col, number>
##   + value: <header>
##   where
##   + col:      `cHeader`
##   + number:   `BlockNumber`
##   + header:   `Header`
##
## * block access lists:
##   + key9: <col, number>
##   + value: <bal>
##   where
##   + col:      `cBal`
##   + number:   `BlockNumber`
##   + bal:      `BlockAccessList`
##

{.push raises: [].}

import
  pkg/[eth/common, results, stew/endians2],
  ./[cache_api1, cache_api9, cache_desc,
     cache_const, cache_iter, cache_rlp]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hasHeader*(db: CacheDbRef, bn = BlockNumber(0)): BoolResult =
  let data = db.get9(cHeader, bn).valueOr:
    return err(error)
  ok(0 < data.len)

proc getHeader*(db: CacheDbRef, bn: BlockNumber): OptHeaderResult =
  let data = db.get9(cHeader, bn).valueOr:
    return err(error)
  if data.len == 0:
    return ok(Opt.none(Header))
  let hdr = data.decodeHeader().valueOr:
    return err(error)
  ok Opt.some(hdr)

proc getBlockHash*(db: CacheDbRef, bn: BlockNumber): OptHashResult =
  db.getHeader(bn + 1).isErrOr:
    if value.isSome():
      return ok Opt.some(value.unsafeGet.parentHash)
  let hdr = db.getHeader(bn).valueOr:
    return err(error)
  if hdr.isNone():
    return ok Opt.none(Hash32)
  ok Opt.some(hdr.unsafeGet.computeBlockHash)

proc lastHeader*(db: CacheDbRef): OptHeaderResult =
  let data = db.get9(cHeader, 0u64).valueOr:
    return err(error)
  if data.len != 8:
    return err("")
  db.getHeader uint64.fromBytesBE data

proc lastNumber*(db: CacheDbRef): BlockNumber =
  let data = db.get9(cHeader, 0u64).valueOr:
    return BlockNumber(0)
  if data.len != 8:
    return BlockNumber(0)
  uint64.fromBytesBE data

proc putHeader*(db: CacheDbRef, header: Header): PutResult =
  db.put9(cHeader, header.number, header.encodeHeader()).isOkOr:
    return err(error)
  db.put9(cHeader, 0u64, uint64(header.number).toBytesBE()).isOkOr:
    return err(error)
  ok()

proc putHeader*(db: CacheDbRef, headers: openArray[Header]): PutResult =
  for h in headers:
    db.put9(cHeader, h.number, h.encodeHeader()).isOkOr:
      return err(error)
  db.put9(cHeader, 0u64, uint64(headers[^1].number).toBytesBE()).isOkOr:
    return err(error)
  ok()

proc delHeader*(db: CacheDbRef, bn: BlockNumber): DelResult =
  db.del9(cHeader, bn)

proc clearHeader*(db: CacheDbRef): DelResult =
  db.clr1 cHeader

iterator walkHeader*(db: CacheDbRef): WalkHeader =
  for (key,data) in db.adb.colWalk9 key9(cHeader, 1u64):
    let header = data.decodeHeader().valueOr:
      var oops: WalkHeader
      oops.error = error
      yield oops
      continue
    yield (header,"")

# -------------

proc hasBal*(db: CacheDbRef, bn = BlockNumber(0)): BoolResult =
  let data = db.get9(cBal, bn).valueOr:
    return err(error)
  ok(0 < data.len)

proc getBal*(db: CacheDbRef, bn: BlockNumber): OptBalResult =
  let data = db.get9(cBal, bn).valueOr:
    return err(error)
  if data.len == 0:
    return ok(Opt.none(BlockAccessListRef))
  let bal = data.decodeBal().valueOr:
    return err(error)
  ok(Opt.some(bal))

proc putBal*(
    db: CacheDbRef;
    bn: BlockNumber;
    bal: BlockAccessListRef;
      ): PutResult =
  db.put9(cBal, bn, bal.encodeBal()).isOkOr:
    return err(error)
  ok()

proc delBal*(db: CacheDbRef, bn: BlockNumber): DelResult =
  db.del9(cBal, bn)

proc clearBal*(db: CacheDbRef): DelResult =
  db.clr1 cBal

iterator walkBal*(db: CacheDbRef): WalkBal =
  for (key,data) in db.adb.colWalk9 key9(cBal):
    let bal = data.decodeBal().valueOr:
      var oops: WalkBal
      oops.error = error
      yield oops
      continue
    yield (bal,"")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
