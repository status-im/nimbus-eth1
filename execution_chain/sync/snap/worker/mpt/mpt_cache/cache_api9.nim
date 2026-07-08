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
  pkg/[eth/common, stew/endians2],
  ./[cache_const, cache_desc, cache_r_cmd]

# ------------------------------------------------------------------------------
# Public API for internal use
# ------------------------------------------------------------------------------

template key9*(col: MptAsmCol; key1: uint64): openArray[byte] =
  var keyData: array[9,byte]
  let key1Data = key1.toBytesBE()
  keyData[0] = col.ord
  (addr keyData[1]).copyMem(addr key1Data[0], 8)
  keyData.toOpenArray(0,8)

template key9*(col: MptAsmCol): openArray[byte] =
  var key: array[9,byte]
  key[0] = col.ord
  key.toOpenArray(0,8)

template get9*(db: CacheDbRef; col: MptAsmCol; key1: uint64): untyped =
  db.adb.rGet(col.key9 key1)

template put9*(
    db: CacheDbRef;
    col: MptAsmCol;
    key1: uint64;
    data: openArray[byte];
      ): untyped =
  db.adb.rPut(col.key9 key1, data)

template del9*(db: CacheDbRef; col: MptAsmCol; key1: uint64): untyped =
  db.adb.rDel(col.key9 key1)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
