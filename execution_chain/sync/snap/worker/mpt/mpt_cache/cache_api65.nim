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

template keyAtMost65(
    col: MptAsmCol;
    key1: untyped;
    key2: openArray[byte];
      ): openArray[byte] =
  doAssert key2.len < 33
  var keyData: array[65,byte]
  keyData[0] = col.ord
  (addr keyData[1]).copyMem(addr (key1.distinctBase)[0], 32)
  (addr keyData[33]).copyMem(addr key2[0], key2.len)
  keyData.toOpenArray(0, 32 + key2.len)

template keyAtMost65(
    col: MptAsmCol;
    key: openArray[byte];
      ): openArray[byte] =
  doAssert key.len < 65
  var keyData: array[65,byte]
  keyData[0] = col.ord
  (addr key[1]).copyMem(addr key[0], key.len)
  keyData.toOpenArray(0, key.len)

# ------------------------------------------------------------------------------
# Public API for internal use
# ------------------------------------------------------------------------------

template key65*(col: MptAsmCol; key1: untyped): openArray[byte] =
  var key: array[65,byte]
  key[0] = col.ord
  (addr key[1]).copyMem(addr (key1.distinctBase)[0], 32)
  key.toOpenArray(0,64)

template key65*(col: MptAsmCol): openArray[byte] =
  var key: array[65,byte]
  key[0] = col.ord
  key.toOpenArray(0,64)

template getAtMost65*(
    db: MptAsmRef;
    col: MptAsmCol;
    key1: untyped;
    key2: openArray[byte];
      ): untyped =
  db.adb.rGet col.keyAtMost65(key1, key2)

template putAtMost65*(
    db: MptAsmRef;
    col: MptAsmCol;
    key1: untyped;
    key2: openArray[byte];
    data: openArray[byte];
      ): untyped =
  if key2.len == 0:
    PutResult.err("zero secondary key not allowed")
  else:
    db.adb.rPut(col.keyAtMost65(key1, key2), data)

template delAtMost65*(
    db: MptAsmRef;
    col: MptAsmCol;
    key1: untyped;
    key2: openArray[byte];
      ): untyped =
  db.adb.rDel col.keyAtMost65(key1, key2)

# --------------

template key65*(col: MptAsmCol; key1, key2: untyped): openArray[byte] =
  var key: array[65,byte]
  key[0] = col.ord
  (addr key[1]).copyMem(addr (key1.distinctBase)[0], 32)
  (addr key[33]).copyMem(addr (key2.distinctBase)[0], 32)
  key.toOpenArray(0,64)

template get65*(
    db: MptAsmRef;
    col: MptAsmCol;
    root: StateRoot;
    start: ItemKey;
      ): untyped =
  let startHash = start.to(Hash32)
  db.adb.rGet col.key65(root, startHash)

template get65*(
    db: MptAsmRef;
    col: MptAsmCol;
    path: Hash32;
    key: Hash32;
      ): untyped =
  db.adb.rGet col.key65(path, key)

template put65*(
    db: MptAsmRef;
    col: MptAsmCol;
    root: StateRoot;
    start: ItemKey;
    data: openArray[byte];
      ): untyped =
  let startHash = start.to(Hash32)
  db.adb.rPut(col.key65(root, startHash), data)

template put65*(
    db: MptAsmRef;
    col: MptAsmCol;
    path: Hash32;
    key: Hash32;
    data: openArray[byte];
      ): untyped =
  db.adb.rPut(col.key65(path, key), data)

template del65*(
    db: MptAsmRef;
    col: MptAsmCol;
    root: StateRoot;
    start: ItemKey;
      ): untyped =
  let startHash = start.to(Hash32)
  db.adb.rDel col.key65(root, startHash)

template del65*(
    db: MptAsmRef;
    col: MptAsmCol;
    path: Hash32;
    key: Hash32;
      ): untyped =
  db.adb.rDel col.key65(path, key)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
