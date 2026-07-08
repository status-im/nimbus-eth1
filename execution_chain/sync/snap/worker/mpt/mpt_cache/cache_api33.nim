# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed

{.push raises: [].}

import
  std/typetraits,
  pkg/eth/common,
  ../../state_db,
  ./[cache_const, cache_desc, cache_r_cmd]

# ------------------------------------------------------------------------------
# Private  helpers
# ------------------------------------------------------------------------------

template keyAtMost33(col: MptAsmCol; key: openArray[byte]): openArray[byte] =
  doAssert key.len < 33
  var keyData: array[33,byte]
  keyData[0] = col.ord
  (addr keyData[1]).copyMem(addr key[0], key.len)
  keyData.toOpenArray(0,key.len)

# ------------------------------------------------------------------------------
# Public API for internal use
# ------------------------------------------------------------------------------

template getAtMost33*(
    db: CacheDbRef;
    col: MptAsmCol;
    key: openArray[byte];
      ): untyped =
  db.adb.rGet(col.keyAtMost33 key)

template putAtMost33*(
    db: CacheDbRef;
    col: MptAsmCol;
    key: openArray[byte];
    data: openArray[byte];
      ): untyped =
  if key.len == 0:
    PutResult.err("zero key not allowed")
  else:
    db.adb.rPut(col.keyAtMost33 key, data)

template delAtMost33*(
    db: CacheDbRef;
    col: MptAsmCol;
    key: openArray[byte];
      ): untyped =
  db.adb.rDel col.keyAtMost33(key)

# --------------

template key33*(col: MptAsmCol; key1: untyped): openArray[byte] =
  var key: array[33,byte]
  key[0] = col.ord
  when key1 is seq[byte]:
    (addr key[1]).copyMem(addr key1[0], 32)
  elif key1 is openArray[byte]:
    let key2 = @key1
    (addr key[1]).copyMem(addr key2[0], 32)
  else:
    (addr key[1]).copyMem(addr (key1.distinctBase)[0], 32)
  key.toOpenArray(0,32)

template key33*(col: MptAsmCol): openArray[byte] =
  var key: array[33,byte]
  key[0] = col.ord
  key.toOpenArray(0,32)

template get33*(db: CacheDbRef; col: MptAsmCol; key1: untyped): untyped =
  db.adb.rGet(col.key33 key1)

template put33*(
    db: CacheDbRef;
    col: MptAsmCol;
    key1: untyped;
    data: openArray[byte];
      ): untyped =
  db.adb.rPut(col.key33 key1, data)

template del33*(db: CacheDbRef; col: MptAsmCol; key1: untyped): untyped =
  db.adb.rDel(col.key33 key1)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
