# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Dangling KVT/MPT references
## ---------------------------
##
## * Dangling account links table:
##   + key33: <col, key>
##   + value: dngl-path
##   where
##   + col:       `AccDnglKvt`
##   + key:       `seq[byte]`
##   * dngl-path: `seq[byte]`
##
## * Dangling storage slot links table:
##   + key65: <col, acc-path, key>
##   + value: dngl-path
##   where
##   + col:       `cStoDnglKvt`
##   + acc-path:  `Hash32`
##   + key:       `seq[byte]`
##   * dngl-path: `seq[byte]`
##
## * Missing contract codes table:
##   + key33: <col, key>
##   + value: path
##   where
##   + col:       `cCodeMissKvt`
##   + key:       `seq[byte]`
##   * path:      `seq[byte]`
##

{.push raises: [].}

import
  pkg/[eth/common, results],
  ../mpt_desc,
  ./[cache_api33, cache_api65,
     cache_const, cache_desc, cache_iter, cache_r_cmd]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------


proc hasAccDnglKvt*(db: MptAsmRef; key: openArray[byte]): BoolResult =
  let data = db.getAtMost33(cAccDnglKvt, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getAccDnglKvt*(db: MptAsmRef; key: openArray[byte]): BlobResult =
  var data = db.getAtMost33(cAccDnglKvt, key).valueOr:
    return err(error)
  ok(move data)

proc putAccDnglKvt*(db: MptAsmRef; key, path: openArray[byte]): PutResult =
  db.putAtMost33(cAccDnglKvt, key, path)

proc putAccDnglKvt*(db: MptAsmRef, kvp: openArray[KpPair]): PutResult =
  for w in kvp:
    db.putAtMost33(cAccDnglKvt, w.key, w.path).isOkOr:
      return err(error)
  ok()

proc delAccDnglKvt*(db: MptAsmRef, key: openArray[byte]): DelResult =
  db.delAtMost33(cAccDnglKvt, key)

proc delAccDnglKvt*(db: MptAsmRef, keys: openArray[seq[byte]]): DelResult =
  for key in keys:
    db.delAtMost33(cAccDnglKvt, key).isOkOr:
      return err(error)
  ok()

proc clearAccDnglKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(cAccDnglKvt)

iterator walkAccDnglKvt*(db: MptAsmRef): KpPair =
  for (key,path) in db.adb.colWalkAtLeast1 @[byte cAccDnglKvt]:
    yield (key,path)

# -------------

proc hasStoDnglKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): BoolResult =
  let data = db.getAtMost65(cStoDnglKvt, acc, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getStoDnglKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): BlobResult =
  var data = db.getAtMost65(cStoDnglKvt, acc, key).valueOr:
    return err(error)
  ok(move data)

proc putStoDnglKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
    data: openArray[byte];
      ): PutResult =
  db.putAtMost65(cStoDnglKvt, acc, key, data)

proc putStoDnglKvt*(
    db: MptAsmRef;
    acc: Hash32;
    kvp: openArray[KpPair];
      ): PutResult =
  for w in kvp:
    db.putAtMost65(cStoDnglKvt, acc, w.key, w.path).isOkOr:
      return err(error)
  ok()

proc delStoDnglKvt*(
    db: MptAsmRef,
    acc: Hash32;
    key: openArray[byte];
      ): DelResult =
  db.delAtMost65(cStoDnglKvt, acc, key)

proc delStoDnglKvt*(
    db: MptAsmRef,
    acc: Hash32;
    keys: openArray[seq[byte]];
      ): DelResult =
  for key in keys:
    db.delAtMost65(cStoDnglKvt, acc, key).isOkOr:
      return err(error)
  ok()

proc clearStoDnglKvt*(db: MptAsmRef, acc: Hash32): DelResult =
  for (key1, key2,_) in db.adb.colWalkAtLeast33 key33(cStoDnglKvt, acc):
    db.delAtMost65(cStoDnglKvt, key1, key2).isOkOr:
      return err(error)
  ok()

proc clearStoDnglKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(cStoDnglKvt)

iterator walkStoDnglKvt*(db: MptAsmRef, acc: Hash32): KkpTriple =
  for (key1, key2, path) in db.adb.colWalkAtLeast33 key33(cStoDnglKvt, acc):
    yield (key1, key2, path)

iterator walkStoDnglKvt*(db: MptAsmRef): KkpTriple =
  for (key,path) in db.adb.colWalkAtLeast1 @[byte cStoDnglKvt]:
    if 32 < key.len:
      yield (key[0..31], key[32..^1], path)

# -------------

proc hasCodeMissKvt*(db: MptAsmRef; key: openArray[byte]): BoolResult =
  let data = db.getAtMost33(cCodeMissKvt, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getCodeMissKvt*(db: MptAsmRef; key: openArray[byte]): BlobResult =
  var data = db.getAtMost33(cCodeMissKvt, key).valueOr:
    return err(error)
  ok(move data)

proc putCodeMissKvt*(db: MptAsmRef; key, path: openArray[byte]): PutResult =
  db.putAtMost33(cCodeMissKvt, key, path)

proc putCodeMissKvt*(db: MptAsmRef; w: KpPair): PutResult =
  db.putAtMost33(cCodeMissKvt, w.key, w.path)

proc putCodeMissKvt*(
    db: MptAsmRef;
    kvp: openArray[KpPair];
      ): PutResult =
  for w in kvp:
    db.putAtMost33(cCodeMissKvt, w.key, w.path).isOkOr:
      return err(error)
  ok()

proc delCodeMissKvt*(db: MptAsmRef, key: openArray[byte]): DelResult =
  db.delAtMost33(cCodeMissKvt, key)

proc delCodeMissKvt*(db: MptAsmRef, keys: openArray[seq[byte]]): DelResult =
  for key in keys:
    db.delAtMost33(cCodeMissKvt, key).isOkOr:
      return err(error)
  ok()

proc clearCodeMissKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(cCodeMissKvt)

iterator walkCodeMissKvt*(db: MptAsmRef): KpPair =
  for (key, path) in db.adb.colWalkAtLeast1 @[byte cCodeMissKvt]:
    yield (key, path)

# -------------

template withDnglAccSto*(db: MptAsmRef, code: untyped): untyped =
  ## Run `code` while advisory lock is set. The only use of this lock is
  ## to make sure that the `hasDnglAccSto()` returns empty only if
  ##
  ## * there is no `withDnglAccSto()` code active, and
  ## * the dangling `*cAccDnglKvt` or `*cStoDnglKvt` tables are empty.
  ##
  block:
    db.dnglLock.inc
    defer: db.dnglLock.dec
    code

proc hasDnglAccSto*(db: MptAsmRef): bool =
  ## Return `true` if a lock was set or some of the `*DnglKvt` tables
  ## contain data.
  ##
  if 0 < db.dnglLock:
    return true
  for _ in db.walkAccDnglKvt:
    return true
  for _ in db.walkStoDnglKvt:
    return true
  # false

template withMissContracts*(db: MptAsmRef, code: untyped): untyped =
  ## Run `code` while advisory lock is set. The only use of this lock is
  ## to make sure that the `hasDangling()` returns empty only if
  ##
  ## * there is no `withDangling()` code active, and
  ## * the dangling tables are empty.
  ##
  block:
    db.cntrLock.inc
    defer: db.cntrLock.dec
    code

proc hasMissContracts*(db: MptAsmRef): bool =
  if 0 < db.cntrLock:
    return true
  for _ in db.walkCodeMissKvt:
    return true
  # false

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
