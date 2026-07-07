# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Partial KVT/MPT records
## -----------------------
##
## * Accounts MPT:
##   + key33: <col, key>
##   + value: node
##   where
##   + col:       `cAccKvt`
##   + key:       `seq[byte]`
##   * node:      `seq[byte]`
##
## * Storage MPTs:
##   + key65: <col, acc-path, key>
##   + value: node
##   where
##   + col:       `cStoKvt`
##   + acc-path:  `Hash32`
##   + key:       `seq[byte]`
##   * node:      `seq[byte]`
##
## * Contract codes table:
##   + key33: <col, key>
##   + value: contract
##   where
##   + col:       `cCodeKvt`
##   + key:       `seq[byte]`
##   * contract:  `seq[byte]`
##

{.push raises: [].}

import
  pkg/[eth/common, results],
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db,
  ../mpt_desc,
  ./[cache_api33, cache_api65,
     cache_const, cache_desc, cache_iter, cache_r_cmd]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hasAccKvt*(db: MptAsmRef; key: openArray[byte]): BoolResult =
  var data = db.getAtMost33(cAccKvt, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getAccKvt*(db: MptAsmRef; key: openArray[byte]): BlobResult =
  var data = db.getAtMost33(cAccKvt, key).valueOr:
    return err(error)
  ok(move data)

proc putAccKvt*(db: MptAsmRef; key, node: openArray[byte]): PutResult =
  db.putAtMost33(cAccKvt, key, node).isOkOr:
    return err(error)
  ok()

proc putAccKvt*(db: MptAsmRef; nodes: openArray[KnPair]): PutResult =
  for w in nodes:
    db.putAtMost33(cAccKvt, w.key, w.node).isOkOr:
      return err(error)
  ok()

proc delAccKvt*(db: MptAsmRef, key: openArray[byte]): DelResult =
  db.delAtMost33(cAccKvt, key)

proc clearAccKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(cAccKvt)

iterator walkAccKvt*(db: MptAsmRef): KnPair =
  for (key,node) in db.adb.colWalkAtLeast1 @[byte cAccKvt]:
    yield (key,node)

# -------------

proc hasStoKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): BoolResult =
  let data = db.getAtMost65(cStoKvt, acc, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getStoKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): BlobResult =
  var data = db.getAtMost65(cStoKvt, acc, key).valueOr:
    return err(error)
  ok(move data)

proc putStoKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key, node: openArray[byte];
      ): PutResult =
  db.putAtMost65(cStoKvt, acc, key, node).isOkOr:
    return err(error)
  ok()

proc putStoKvt*(
    db: MptAsmRef;
    acc: Hash32;
    nodes: openArray[KnPair];
      ): PutResult =
  for w in nodes:
    db.putAtMost65(cStoKvt, acc, w.key, w.node).isOkOr:
      return err(error)
  ok()

proc delStoKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): DelResult =
  db.delAtMost65(cStoKvt, acc, key)

proc clearStoKvt*(db: MptAsmRef, acc: Hash32): DelResult =
  for (key1, key2,_) in db.adb.colWalkAtLeast33 key33(cStoKvt, acc):
    db.delAtMost65(cStoKvt, key1, key2).isOkOr:
      return err(error)
  ok()

proc clearStoKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(cStoKvt)

iterator walkStoKvt*(db: MptAsmRef, acc: Hash32): KkpTriple =
  for (key1, key2, path) in db.adb.colWalkAtLeast33 key33(cStoKvt, acc):
    yield (key1, key2, path)

iterator walkStoKvt*(db: MptAsmRef): KkpTriple =
  for (key,path) in db.adb.colWalkAtLeast1 @[byte cStoKvt]:
    if 32 < key.len:
      yield (key[0..31], key[32..^1], path)

# -------------

proc hasCodeKvt*(db: MptAsmRef; hash: Hash32): BoolResult =
  let data = db.get33(cCodeKvt, hash).valueOr:
    return err(error)
  ok(0 < data.len)

proc getCodeKvt*(db: MptAsmRef; hash: Hash32): BlobResult =
  var data = db.get33(cCodeKvt, hash).valueOr:
    return err(error)
  ok(move data)

proc putCodeKvt*(db: MptAsmRef; key, data: openArray[byte]): PutResult =
  db.put33(cCodeKvt, key, data)

proc putCodeKvt*(db: MptAsmRef; cdHash: CodeHash; data: CodeItem): PutResult =
  db.put33(cCodeKvt, cdHash.to(Hash32), data.to(seq[byte]))

proc putCodeKvt*(db: MptAsmRef; contracts: openArray[KvPair]): PutResult =
  for w in contracts:
    db.put33(cCodeKvt, w.key, w.value).isOkOr:
      return err(error)
  ok()

proc delCodeKvt*(db: MptAsmRef, hash: Hash32): DelResult =
  db.del33(cCodeKvt, hash)

proc clearCodeKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(cCodeKvt)

iterator walkCodeKvt*(db: MptAsmRef): KvPair =
  for (key,value) in db.adb.colWalkAtLeast1 @[byte cCodeKvt]:
    yield (key,value)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
