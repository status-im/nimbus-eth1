# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Persistent Storage or Cache For Snap Data And MPT Assembly
## ==========================================================
##
## For the moment, this module is a separate RocksDB unit independent
## from `CoreDB`/`Aristo`/`Kvt`. If/when it proves to be useful, it can
## be integrated with KVT, similar to `BeaconHeaderKey` from the
## `header_chain_cache` module.
##
## This module will always pull in the `RocksDB` library. There is no
## in-memory part (which avoids the `RocksDB` library) as provided by the
## `CoreDb` via different `memory` and `persistent` sub-modules.
##
## No column families are used, here.
##
## Key/value storage formats by column type:
##
## * RawAccPkg:
##   + key65: <col, root, start>
##   + value: <limit, packet, peerID>
##   where
##   + col: `RawAccPkg`
##   + root: `StateRoot`
##   + start: `ItemKey`
##   + limit: `ItemKey`
##   + packet: `AccountRangePacket`
##   + peerID: `Hash`
##
## * MptAccounts:
##   + key65: <col, root, start>
##   + value: <[key, node],..>
##   where
##   + col: `MptAccounts`
##   + root: `StateRoot`
##   + start: `ItemKey`
##   + key: `seq[byte]` with 0 < length <= 32
##   + node: `seq[byte]` with 0 < length
##
## Additional assumptions:
##
## * The `CoreDB`/`Aristo`/`Kvt` state database suite is mostly idle,
##   typically it would be empty. This only matters when the MPT assembly
##   needs to be imported. The current state database needs to be cleared
##   before import.
##

{.push raises: [].}

import
  std/[dirs, paths, typetraits],
  pkg/[chronicles, chronos, eth/common, results, rocksdb, stew/byteutils],
  ../../../wire_protocol/snap/snap_types,
  ../[state_db, worker_const],
  ./mpt_desc

logScope:
  topics = "snap sync"

const
  EmptyBlob = seq[byte].default

  extraTraceMessages = true
    ## Enable additional logging noise

type
  MptAsmCol = enum
    AdminCol = 0
    RawAccPkg                                     # as fetched from network
    MptAccounts,                                  # list of (key,none) pairs

  MptAsmRef* = ref object
    adb*: RocksDbReadWriteRef
    dir*: Path

  DecodedRawAccPkg* = tuple
    limit: ItemKey
    packet: AccountRangePacket
    peerID: Hash

  WalkRawAccPkg* = tuple
    root: StateRoot
    start: ItemKey
    limit: ItemKey
    packet: AccountRangePacket
    peerID: Hash
    error: string

# ------------------------------------------------------------------------------
# Private RLP helpers
# ------------------------------------------------------------------------------

func decodeRawAccPkg(data: seq[byte]): Result[DecodedRawAccPkg,string] =
  when sizeof(Hash) != sizeof(uint):
    {.error: "Hash type must have size of uint".}
  const info = "decodeRawAccPkg"
  var
    rd = data.rlpFromBytes
    res: DecodedRawAccPkg
  try:
    rd.tryEnterList()
    res.limit = ItemKey(rd.read(UInt256))
    res.packet = rd.read(AccountRangePacket)
    res.peerID = Hash(cast[int](rd.read uint))
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

template encodeRawAccPkg(
    limit: ItemKey;
    packet: AccountRangePacket;
    peerID: Hash;
      ): untyped =
  when sizeof(Hash) != sizeof(uint):
    {.error: "Hash type must have size of uint".}
  var wrt = initRlpList 3
  wrt.append limit.to(UInt256)
  wrt.append packet
  wrt.append cast[uint](peerID)
  wrt.finish()

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc rGet(
    adb: RocksDbRef;
    key: openArray[byte];
      ): Result[seq[byte],string] =
  const info = "mpt/get: "

  var res: seq[byte]
  proc onData(data: openArray[byte]) =
    res = @data

  let rc = adb.get(key, onData)
  if rc.isErr:
    when extraTraceMessages:
      trace info & "key not found", key=key.toHex, `error`=rc.error
    return err(info & rc.error)

  if not rc.value:
    res = EmptyBlob
  ok(move res)

proc rPut(
    adb: RocksDbReadWriteRef;
    key: openArray[byte];
    data: openArray[byte];
      ): Result[void,string] =
  const info = "mpt/put: "
  adb.put(key, data).isOkOr:
    when extraTraceMessages:
      trace info & "failed", key=key.toHex, `error`=error
    return err(info & error)
  ok()

proc rDel(
    adb: RocksDbReadWriteRef;
    key: openArray[byte];
      ): Result[void,string] =
  const info = "mpt/del: "
  adb.delete(key).isOkOr:
    when extraTraceMessages:
      trace info & "failed", key=key.toHex, `error`=error
    return err(info & error)
  ok()

# --------------

iterator rWalk(
    adb: RocksDbRef;
    pfx: openArray[byte];
      ): tuple[key: seq[byte], data: seq[byte]] =
  ## Walk over key-value pairs of the hash key column of the database.
  ##
  const info = "mpt/walk: "
  block walkBody:
    let rit = adb.openIterator().valueOr:
      when extraTraceMessages:
        trace info & "Open error", error
      break walkBody
    defer: rit.close()

    if pfx.len == 0:
      rit.seekToFirst()
    else:
      rit.seekToKey(pfx)

    var key, val: seq[byte]
    proc readKey(w: openArray[byte]) = key = @w
    proc readVal(w: openArray[byte]) = val = @w

    while rit.isValid():
      rit.key(readKey)
      rit.value(readVal)
      rit.next()
      yield (key, val)

iterator rWalk65(
    adb: RocksDbRef;
    pfx: openArray[byte];
      ): tuple[col: MptAsmCol, key1, key2: Hash32, data: seq[byte]] =
  ## Variant of `rWalk()` for 65 byte keys
  ##
  var key1, key2: Hash32
  for (key,value) in adb.rWalk(pfx):
    const
      minKey0 = low(MptAsmCol).ord.byte
      maxKey0 = high(MptAsmCol).ord.byte
    if key.len == 65 and minKey0 <= key[0] and key[0] <= maxKey0:
      (addr (key1.distinctBase)[0]).copyMem(addr key[1], 32)
      (addr (key2.distinctBase)[0]).copyMem(addr key[33], 32)
      yield (MptAsmCol(key[0]), key1, key2, value)

iterator rWalk65(
    adb: RocksDbRef;
    pfx: openArray[byte];
    col: MptAsmCol;
      ): tuple[key1, key2: Hash32, data: seq[byte]] =
  ## Variant of `rWalk()` for 65 byte keys
  ##
  var key1, key2: Hash32
  for (key,value) in adb.rWalk(pfx):
    if 0 < key.len and col.ord.byte != key[0]:
      break
    if key.len == 65:
      (addr (key1.distinctBase)[0]).copyMem(addr key[1], 32)
      (addr (key2.distinctBase)[0]).copyMem(addr key[33], 32)
      yield (key1, key2, value)

# --------------

template key65(col: MptAsmCol; key1, key2: untyped): openArray[byte] =
  var key: array[65,byte]
  key[0] = col.ord
  (addr key[1]).copyMem(addr (key1.distinctBase)[0], 32)
  (addr key[33]).copyMem(addr (key2.distinctBase)[0], 32)
  key.toOpenArray(0,64)

template key65(col: MptAsmCol; key1: untyped): openArray[byte] =
  var key: array[65,byte]
  key[0] = col.ord
  (addr key[1]).copyMem(addr (key1.distinctBase)[0], 32)
  key.toOpenArray(0,64)

template key65(col: MptAsmCol): openArray[byte] =
  var key: array[65,byte]
  key[0] = col.ord
  key.toOpenArray(0,64)

template get65(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    col: MptAsmCol;
      ): untyped =
  let startHash = start.to(Hash32)
  db.adb.rGet(col.key65(root, startHash))

template put65(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    data: openArray[byte];
    col: MptAsmCol;
      ): untyped =
  let startHash = start.to(Hash32)
  db.adb.rPut(col.key65(root, startHash), data)

template del65(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    col: MptAsmCol;
      ): untyped =
  let startHash = start.to(Hash32)
  db.adb.rDel(col.key65(root, startHash))

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(T: type MptAsmRef, baseDir: string, info: static[string]): Opt[T] =
  if baseDir.len == 0:
    error info & "No base directory for assembly DB"
    return err()

  let asmDir = Path(baseDir) / Path(snapAsmFolder)
  if asmDir.dirExists:
    let bakDir = Path(asmDir.distinctBase & "~")
    block backupOldFolder:
      var excpt = ""
      try:
        bakDir.removeDir()
        asmDir.moveDir bakDir
        break backupOldFolder
      except OSError as e:
        excpt = $e.name & "(" & e.msg & ")"
      except IOError as e:
        excpt = $e.name & "(" & e.msg & ")"
      error info & ": Cannot backup old assembly folder", asmDir, bakDir, excpt
      return err()

    when extraTraceMessages: # FIXME: debugging -- will go away
      let adb = bakDir.distinctBase.openRocksDb().valueOr:
        error info & ": Can't create assembly DB", bakDir, `error`=error
        return err()
      defer: adb.close()
      for (col,key1,key2,val) in adb.rWalk65(EmptyBlob):
        trace info & ": dump", bak=bakDir.splitFile.name,
          col, key1=key1.toStr, key2=key2.toStr, nData=val.len

  block createSnapFolder:
    var excpt = ""
    try:
      asmDir.createDir()
      break createSnapFolder
    except OSError as e:
      excpt = $e.name & "(" & e.msg & ")"
    except IOError as e:
      excpt = $e.name & "(" & e.msg & ")"
    error info & ": Cannot create assembly folder", asmDir, excpt
    return err()

  let db = T(dir: asmDir)
  db.adb = asmDir.distinctBase.openRocksDb().valueOr:
    error info & ": Cannot create rocksdb assembly DB", asmDir, `error`=error
    return err()

  ok db

proc close*(db: MptAsmRef, eradicate = false) =
  db.adb.close()
  db.adb = nil
  if eradicate:
    try:
      db.dir.removeDir()

      # Remove the base folder if it is empty
      block done:
        for w in db.dir.walkDirRec():
          # Ignore backup files
          let p = w.distinctBase
          if 0 < p.len and p[^1] != '~':
            break done
        db.dir.removeDir()
    except CatchableError:
      discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getMptAccounts*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): Result[seq[(seq[byte],seq[byte])],string] =
  let data = db.get65(root, start, MptAccounts).valueOr:
    return err(error)

  const info = "getMptAccounts: "
  var decoded: seq[(seq[byte],seq[byte])]
  try:
    decoded = rlp.decode(data, typeof decoded)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")

  ok(move decoded)

proc putMptAccounts*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    data: seq[(seq[byte],seq[byte])];
      ): Result[void,string] =
  db.put65(root, start, rlp.encode(data), MptAccounts)

proc delMptAccounts*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): Result[void,string] =
  db.del65(root, start, MptAccounts)

iterator walkMptAccounts*(
    db: MptAsmRef;
      ): tuple[root: StateRoot, start: ItemKey, data: seq[byte]] =
  for (key1,key2,val) in db.adb.rWalk65(MptAccounts.key65(), MptAccounts):
    yield (StateRoot(key1), key2.to(ItemKey), val)

iterator walkMptAccounts*(
    db: MptAsmRef;
    root: StateRoot;
      ): tuple[start: ItemKey, data: seq[byte]] =
  for (key1,key2,val) in db.adb.rWalk65(MptAccounts.key65(root), MptAccounts):
    if key1 != Hash32(root):
      break
    yield (key2.to(ItemKey), val)

# -------------

proc getRawAccPkg*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): Result[DecodedRawAccPkg,string] =
  let data = db.get65(root, start, RawAccPkg).valueOr:
    return err(error)
  data.decodeRawAccPkg()

proc putRawAccPkg*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
    packet: AccountRangePacket;
    peerID: Hash;
      ): Result[void,string] =
  db.put65(root, start, encodeRawAccPkg(limit, packet, peerID), RawAccPkg)

proc delRawAccPkg*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): Result[void,string] =
  db.del65(root, start, RawAccPkg)

iterator walkRawAccPkg*(db: MptAsmRef): WalkRawAccPkg =
  for (key1,key2,value) in db.adb.rWalk65(RawAccPkg.key65(), RawAccPkg):
    let
      root = StateRoot(key1)
      start = key2.to(ItemKey)
      w = value.decodeRawAccPkg().valueOr:
        var oops: WalkRawAccPkg
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w.limit, w.packet, w.peerID, "")

iterator walkRawAccPkg*(db: MptAsmRef, root: StateRoot): WalkRawAccPkg =
  ## Variant of `walkRawAccPkg()` for fixed `root`
  for (key1,key2,value) in db.adb.rWalk65(RawAccPkg.key65(root), RawAccPkg):
    if StateRoot(key1) != root:
      break
    let
      start = key2.to(ItemKey)
      w = value.decodeRawAccPkg().valueOr:
        var oops: WalkRawAccPkg
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w.limit, w.packet, w.peerID, "")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
