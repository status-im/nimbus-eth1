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
##   + col:       `cAccPartMpt`
##   + key:       `seq[byte]`
##   * node:      `seq[byte]`
##
## * Dangling account paths:
##   + key33: <col, key>
##   + value: dngl-path
##   where
##   + col:       `cAccDnglPath`
##   + key:       `seq[byte]`
##
## * Storage MPTs:
##   + key65: <col, acc-path, key>
##   + value: node
##   where
##   + col:       `cStoPartMpt`
##   + acc-path:  `Hash32`
##   + key:       `seq[byte]`
##   * node:      `seq[byte]`
##
## * Contract codes table:
##   + key33: <col, key>
##   + value: contract
##   where
##   + col:       `cCodePartMpt`
##   + key:       `seq[byte]`
##   * contract:  `seq[byte]`
##   * dngl-path: `seq[byte]`
##

{.push raises: [].}

import
  pkg/[eth/common, results],
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db,
  ../mpt_build/build_desc,
  ./[cache_api1, cache_api33, cache_api65,
     cache_const, cache_desc, cache_iter]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hasAccPartMpt*(db: CacheDbRef; key: openArray[byte]): BoolResult =
  var data = db.getAtMost33(cAccPartMpt, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getAccPartMpt*(db: CacheDbRef; key: openArray[byte]): BlobResult =
  var data = db.getAtMost33(cAccPartMpt, key).valueOr:
    return err(error)
  ok(move data)

proc putAccPartMpt*(db: CacheDbRef; key, node: openArray[byte]): PutResult =
  db.putAtMost33(cAccPartMpt, key, node).isOkOr:
    return err(error)
  ok()

proc putAccPartMpt*(db: CacheDbRef; nodes: openArray[KnPair]): PutResult =
  for w in nodes:
    db.putAtMost33(cAccPartMpt, w.key, w.node).isOkOr:
      return err(error)
  ok()

proc delAccPartMpt*(db: CacheDbRef, key: openArray[byte]): DelResult =
  db.delAtMost33(cAccPartMpt, key)

proc clearAccPartMpt*(db: CacheDbRef): DelResult =
  db.clr1 cAccPartMpt

iterator walkAccPartMpt*(db: CacheDbRef): KnPair =
  for (key,node) in db.adb.colWalkAtLeast1 @[byte cAccPartMpt]:
    yield (key,node)

# -------------

proc hasAccDnglPath*(db: CacheDbRef; key: openArray[byte]): BoolResult =
  let data = db.getAtMost33(cAccDnglPath, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getAccDnglPath*(db: CacheDbRef; key: openArray[byte]): BlobResult =
  var data = db.getAtMost33(cAccDnglPath, key).valueOr:
    return err(error)
  ok(move data)

proc putAccDnglPath*(db: CacheDbRef; key, path: openArray[byte]): PutResult =
  db.putAtMost33(cAccDnglPath, key, path)

proc putAccDnglPath*(db: CacheDbRef, kvp: openArray[KpPair]): PutResult =
  for w in kvp:
    db.putAtMost33(cAccDnglPath, w.key, w.path).isOkOr:
      return err(error)
  ok()

proc delAccDnglPath*(db: CacheDbRef, key: openArray[byte]): DelResult =
  db.delAtMost33(cAccDnglPath, key)

proc delAccDnglPath*(db: CacheDbRef, keys: openArray[seq[byte]]): DelResult =
  for key in keys:
    db.delAtMost33(cAccDnglPath, key).isOkOr:
      return err(error)
  ok()

proc clearAccDnglPath*(db: CacheDbRef): DelResult =
  db.clr1 cAccDnglPath

iterator walkAccDnglPath*(db: CacheDbRef): KpPair =
  for (key,path) in db.adb.colWalkAtLeast1 @[byte cAccDnglPath]:
    yield (key,path)

# -------------

proc hasStoPartMpt*(
    db: CacheDbRef;
    acc: Hash32;
    key: openArray[byte];
      ): BoolResult =
  let data = db.getAtMost65(cStoPartMpt, acc, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getStoPartMpt*(
    db: CacheDbRef;
    acc: Hash32;
    key: openArray[byte];
      ): BlobResult =
  var data = db.getAtMost65(cStoPartMpt, acc, key).valueOr:
    return err(error)
  ok(move data)

proc putStoPartMpt*(
    db: CacheDbRef;
    acc: Hash32;
    key, node: openArray[byte];
      ): PutResult =
  db.putAtMost65(cStoPartMpt, acc, key, node).isOkOr:
    return err(error)
  ok()

proc putStoPartMpt*(
    db: CacheDbRef;
    acc: Hash32;
    nodes: openArray[KnPair];
      ): PutResult =
  for w in nodes:
    db.putAtMost65(cStoPartMpt, acc, w.key, w.node).isOkOr:
      return err(error)
  ok()

proc delStoPartMpt*(
    db: CacheDbRef;
    acc: Hash32;
    key: openArray[byte];
      ): DelResult =
  db.delAtMost65(cStoPartMpt, acc, key)

proc clearStoPartMpt*(db: CacheDbRef, acc: Hash32): DelResult =
  for (key1, key2,_) in db.adb.colWalkAtLeast33 key33(cStoPartMpt, acc):
    db.delAtMost65(cStoPartMpt, key1, key2).isOkOr:
      return err(error)
  ok()

proc clearStoPartMpt*(db: CacheDbRef): DelResult =
  db.clr1 cStoPartMpt

iterator walkStoPartMpt*(db: CacheDbRef, acc: Hash32): KkpTriple =
  for (key1, key2, path) in db.adb.colWalkAtLeast33 key33(cStoPartMpt, acc):
    yield (key1, key2, path)

iterator walkStoPartMpt*(db: CacheDbRef): KkpTriple =
  for (key,path) in db.adb.colWalkAtLeast1 @[byte cStoPartMpt]:
    if 32 < key.len:
      yield (key[0..31], key[32..^1], path)

# -------------

proc hasCodePartMpt*(db: CacheDbRef; hash: Hash32): BoolResult =
  let data = db.get33(cCodePartMpt, hash).valueOr:
    return err(error)
  ok(0 < data.len)

proc getCodePartMpt*(db: CacheDbRef; hash: Hash32): BlobResult =
  var data = db.get33(cCodePartMpt, hash).valueOr:
    return err(error)
  ok(move data)

proc putCodePartMpt*(db: CacheDbRef; key, data: openArray[byte]): PutResult =
  db.put33(cCodePartMpt, key, data)

proc putCodePartMpt*(db: CacheDbRef; cdHash: CodeHash; data: CodeItem): PutResult =
  db.put33(cCodePartMpt, cdHash.to(Hash32), data.to(seq[byte]))

proc putCodePartMpt*(db: CacheDbRef; contracts: openArray[KvPair]): PutResult =
  for w in contracts:
    db.put33(cCodePartMpt, w.key, w.value).isOkOr:
      return err(error)
  ok()

proc delCodePartMpt*(db: CacheDbRef, hash: Hash32): DelResult =
  db.del33(cCodePartMpt, hash)

proc clearCodePartMpt*(db: CacheDbRef): DelResult =
  db.clr1 cCodePartMpt

iterator walkCodePartMpt*(db: CacheDbRef): KvPair =
  for (key,value) in db.adb.colWalkAtLeast1 @[byte cCodePartMpt]:
    yield (key,value)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
