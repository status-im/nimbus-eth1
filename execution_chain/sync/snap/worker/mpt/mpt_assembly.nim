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
## * RawAccounts:
##   + key65: <col, root, start>
##   + value: <limit, accounts, prrof, peerID>
##   where
##   + col:      `RawAccounts`
##   + root:     `StateRoot`
##   + start:    `ItemKey`
##   + limit:    `ItemKey`
##   + accounts: `seq[SnapAccount]`
##   + proof:    `seq[ProofNode]`
##   + peerID:   `Hash`
##
## * RawStoSlot:
##   + key97: <col, root, account, start>
##   + value: <limit, slot, proof, peerID>
##   where
##   + col:      `RawAccounts`
##   + root:     `StateRoot`
##   * account:  `ItemKey`
##   + start:    `ItemKey`
##   + limit:    `ItemKey`
##   + slot:     `seq[StorageItem]`
##   + proof:    `seq[ProofNode]`
##   + peerID:   `Hash`
##
## * RawByteCode:
##   + key65: <col, root, start>
##   + value: <limit, code, peerID>
##   where
##   + col:      `RawByteCodes`
##   + root:     `StateRoot`
##   * start:    `ItemKey`
##   + limit:    `ItemKey`
##   + codes:    `seq[(CodeHash,CodeItem)]`
##   + peerID:   `Hash`
##
## * MptAccounts:
##   + key65: <col, root, start>
##   + value: <limit, partTrie>
##   where
##   + col:      `MptAccounts`
##   + root:     `StateRoot`
##   + start:    `ItemKey`
##   + limit:    `ItemKey`
##   + partTrie: `seq[tuple[key: seq[byte], node: seq[byte]]]`
##   + key:      `seq[byte]` with 0 < length <= 32
##   + node:     `seq[byte]` with 0 < length
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

  EmptyProof = seq[ProofNode].default

  extraTraceMessages = true
    ## Enable additional logging noise

type
  MptAsmCol = enum
    AdminCol = 0
    RawAccounts                                     # as fetched from network
    RawStoSlot                                      # ditto
    RawByteCode                                     # ditto
    MptAccounts                                     # list of (key,node) pairs
    MptStoSlot                                      # list of (key,code) pairs

  MptAsmRef* = ref object
    adb*: RocksDbReadWriteRef
    dir*: Path

  DecodedRawAccounts* = tuple
    limit: ItemKey
    accounts: seq[SnapAccount]
    proof: seq[ProofNode]
    peerID: Hash

  DecodedRawStoSlot* = tuple
    limit: ItemKey
    slot: seq[StorageItem]
    proof: seq[ProofNode]
    peerID: Hash

  DecodedRawByteCode* = tuple
    limit: ItemKey
    codes: seq[(CodeHash,CodeItem)]
    peerID: Hash

  WalkRawAccounts* = tuple
    root: StateRoot
    start: ItemKey
    limit: ItemKey
    accounts: seq[SnapAccount]
    proof: seq[ProofNode]
    peerID: Hash
    error: string

  WalkRawStoSlot* = tuple
    root: StateRoot
    account: ItemKey
    start: ItemKey                                  # `0` unless incomplete
    limit: ItemKey                                  # `high()` unless incomplete
    slot: seq[StorageItem]
    proof: seq[ProofNode]                           # Prof for `slot` (if any)
    peerID: Hash
    error: string

  WalkRawByteCode* = tuple
    root: StateRoot
    start: ItemKey                                  # account coverage
    limit: ItemKey                                  # account coverage
    codes: seq[(CodeHash,CodeItem)]
    peerID: Hash
    error: string

# ------------------------------------------------------------------------------
# Private RLP helpers
# ------------------------------------------------------------------------------

when sizeof(Hash) != sizeof(uint):
  {.error: "Hash type must have size of uint".}

func decodeRawAccounts(data: seq[byte]): Result[DecodedRawAccounts,string] =
  const info = "decodeRawAccounts"
  var
    rd = data.rlpFromBytes
    res: DecodedRawAccounts
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.accounts = rd.read(seq[SnapAccount])
    res.proof = rd.read(seq[ProofNode])
    res.peerID = Hash(cast[int](rd.read uint))
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeRawStoSlot(data: seq[byte]): Result[DecodedRawStoSlot,string] =
  const info = "decodeRawAccounts"
  var
    rd = data.rlpFromBytes
    res: DecodedRawStoSlot
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.slot = rd.read(seq[StorageItem])
    res.proof = rd.read(seq[ProofNode])
    res.peerID = Hash(cast[int](rd.read uint))
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeRawByteCode(data: seq[byte]): Result[DecodedRawByteCode,string] =
  const info = "decodeRawByteCode"
  var
    rd = data.rlpFromBytes
    res: DecodedRawByteCode
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.codes = rd.read(seq[(CodeHash,CodeItem)])
    res.peerID = Hash(cast[int](rd.read uint))
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)


template encodeRawAccounts(
    limit: ItemKey;
    accounts: seq[SnapAccount];
    proof: seq[ProofNode];
    peerID: Hash;
      ): untyped =
  var wrt = initRlpList 4
  wrt.append limit.to(UInt256)
  wrt.append accounts
  wrt.append proof
  wrt.append cast[uint](peerID)
  wrt.finish()

template encodeRawStoSlot(
    limit: ItemKey;
    slot: seq[StorageItem];
    proof: seq[ProofNode];
    peerID: Hash;
      ): untyped =
  var wrt = initRlpList 4
  wrt.append limit.to(UInt256)
  wrt.append slot
  wrt.append proof
  wrt.append cast[uint](peerID)
  wrt.finish()

template encodeRawByteCode(
    limit: ItemKey;
    codes: seq[(CodeHash,CodeItem)];
    peerID: Hash;
      ): untyped =
  const info = "decodeRawByteCode"
  var wrt = initRlpList 3
  wrt.append limit.to(UInt256)
  wrt.append codes
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


iterator rWalk97(
    adb: RocksDbRef;
    pfx: openArray[byte];
      ): tuple[col: MptAsmCol, key1, key2, key3: Hash32, data: seq[byte]] =
  ## Variant of `rWalk()` for 97 byte keys
  ##
  var key1, key2, key3: Hash32
  for (key,value) in adb.rWalk(pfx):
    const
      minKey0 = low(MptAsmCol).ord.byte
      maxKey0 = high(MptAsmCol).ord.byte
    if key.len == 97 and minKey0 <= key[0] and key[0] <= maxKey0:
      (addr (key1.distinctBase)[0]).copyMem(addr key[1], 32)
      (addr (key2.distinctBase)[0]).copyMem(addr key[33], 32)
      (addr (key3.distinctBase)[0]).copyMem(addr key[65], 32)
      yield (MptAsmCol(key[0]), key1, key2, key3, value)

iterator rWalk97(
    adb: RocksDbRef;
    pfx: openArray[byte];
    col: MptAsmCol;
      ): tuple[key1, key2, key3: Hash32, data: seq[byte]] =
  ## Variant of `rWalk()` for 97 byte keys
  ##
  var key1, key2, key3: Hash32
  for (key,value) in adb.rWalk(pfx):
    if 0 < key.len and col.ord.byte != key[0]:
      break
    if key.len == 97:
      (addr (key1.distinctBase)[0]).copyMem(addr key[1], 32)
      (addr (key2.distinctBase)[0]).copyMem(addr key[33], 32)
      (addr (key2.distinctBase)[0]).copyMem(addr key[65], 32)
      yield (key1, key2, key3, value)

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

# --------------

template key97(col: MptAsmCol; key1, key2, key3: untyped): openArray[byte] =
  var key: array[97,byte]
  key[0] = col.ord
  (addr key[1]).copyMem(addr (key1.distinctBase)[0], 32)
  (addr key[33]).copyMem(addr (key2.distinctBase)[0], 32)
  (addr key[65]).copyMem(addr (key3.distinctBase)[0], 32)
  key.toOpenArray(0,96)

template key97(col: MptAsmCol; key1, key2: untyped): openArray[byte] =
  var key: array[97,byte]
  key[0] = col.ord
  (addr key[1]).copyMem(addr (key1.distinctBase)[0], 32)
  (addr key[33]).copyMem(addr (key2.distinctBase)[0], 32)
  key.toOpenArray(0,96)

template key97(col: MptAsmCol; key1: untyped): openArray[byte] =
  var key: array[97,byte]
  key[0] = col.ord
  (addr key[1]).copyMem(addr (key1.distinctBase)[0], 32)
  key.toOpenArray(0,96)

template key97(col: MptAsmCol): openArray[byte] =
  var key: array[97,byte]
  key[0] = col.ord
  key.toOpenArray(0,96)

template get97(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
    col: MptAsmCol;
      ): untyped =
  let
    startHash = start.to(Hash32)
    account = acc.to(Hash32)
  db.adb.rGet(col.key97(root, account, startHash))

template put97(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
    data: openArray[byte];
    col: MptAsmCol;
      ): untyped =
  let
    startHash = start.to(Hash32)
    account = acc.to(Hash32)
  db.adb.rPut(col.key97(root, account, startHash), data)

template del97(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
    col: MptAsmCol;
      ): untyped =
  let
    startHash = start.to(Hash32)
    account = acc.to(Hash32)
  db.adb.rDel(col.key97(root, account, startHash))

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
      for (col,key1,key2,key3,val) in adb.rWalk97(EmptyBlob):
        trace info & ": dump", bak=bakDir.splitFile.name,
          col, key1=key1.toStr, key2=key2.toStr, key3=key3.toStr, nData=val.len

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

proc getRawAccounts*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): Result[DecodedRawAccounts,string] =
  let data = db.get65(root, start, RawAccounts).valueOr:
    return err(error)
  data.decodeRawAccounts()

proc putRawAccounts*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
    accounts: seq[SnapAccount];
    proof: seq[ProofNode];
    peerID: Hash;
      ): Result[void,string] =
  db.put65(
    root, start, encodeRawAccounts(limit, accounts, proof, peerID), RawAccounts)

proc delRawAccounts*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): Result[void,string] =
  db.del65(root, start, RawAccounts)

iterator walkRawAccounts*(db: MptAsmRef): WalkRawAccounts =
  for (key1,key2,value) in db.adb.rWalk65(RawAccounts.key65(), RawAccounts):
    let
      root = StateRoot(key1)
      start = key2.to(ItemKey)
      w = value.decodeRawAccounts().valueOr:
        var oops: WalkRawAccounts
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w.limit, w.accounts, w.proof, w.peerID, "")

iterator walkRawAccounts*(db: MptAsmRef, root: StateRoot): WalkRawAccounts =
  ## Variant of `walkRawAccounts()` for fixed `root`
  for (key1,key2,value) in db.adb.rWalk65(RawAccounts.key65(root), RawAccounts):
    if StateRoot(key1) != root:
      break
    let
      start = key2.to(ItemKey)
      w = value.decodeRawAccounts().valueOr:
        var oops: WalkRawAccounts
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w.limit, w.accounts, w.proof, w.peerID, "")

# -------------

proc getRawStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    account: ItemKey;
    start: ItemKey;
      ): Result[DecodedRawStoSlot,string] =
  let data = db.get97(root, account, start, RawStoSlot).valueOr:
    return err(error)
  data.decodeRawStoSlot()

proc putRawStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
    limit: ItemKey;
    slot: seq[StorageItem];
    proof: seq[ProofNode];
    peerID: Hash;
      ): Result[void,string] =
  db.put97(
    root, acc, start, encodeRawStoSlot(limit, slot, proof, peerID), RawStoSlot)

proc putRawStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    slot: seq[StorageItem];
    peerID: Hash;
      ): Result[void,string] =
  db.put97(
    root, acc, low(ItemKey),
    encodeRawStoSlot(high(ItemKey), slot, EmptyProof, peerID),
    RawStoSlot)

proc delRawStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
      ): Result[void,string] =
  db.del97(root, acc, start, RawStoSlot)

iterator walkRawStoSlot*(db: MptAsmRef): WalkRawStoSlot =
  for (k1,k2,k3,val) in db.adb.rWalk97(RawStoSlot.key97(), RawStoSlot):
    let
      root = k1.to(StateRoot)
      acc = k2.to(ItemKey)
      start = k3.to(ItemKey)
      w = val.decodeRawStoSlot().valueOr:
        var oops: WalkRawStoSlot
        oops.root = root
        oops.account = acc
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, acc, start, w.limit, w.slot, w.proof, w.peerID, "")

iterator walkRawStoSlot*(db: MptAsmRef, root: StateRoot): WalkRawStoSlot =
  ## Variant of `walkRawStoSlot()` for fixed `root`
  for (k1,k2,k3,val) in db.adb.rWalk97(RawStoSlot.key97(root), RawStoSlot):
    if k1.to(StateRoot) != root:
      break
    let
      account = k2.to(ItemKey)
      start = k3.to(ItemKey)
      w = val.decodeRawStoSlot().valueOr:
        var oops: WalkRawStoSlot
        oops.root = root
        oops.account = account
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, account, start, w.limit, w.slot, w.proof, w.peerID, "")

iterator walkRawStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
      ): WalkRawStoSlot =
  ## Variant of `walkRawStoSlot()` for fixed `root`
  let aHash = acc.to(Hash32)
  for (k1,k2,k3,val) in db.adb.rWalk97(RawStoSlot.key97(root,aHash),RawStoSlot):
    if k1.to(StateRoot) != root or
       k2.to(ItemKey) != acc:
      break
    let
      start = k3.to(ItemKey)
      w = val.decodeRawStoSlot().valueOr:
        var oops: WalkRawStoSlot
        oops.root = root
        oops.account = acc
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, acc, start, w.limit, w.slot, w.proof, w.peerID, "")

# -------------

proc getRawByteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
      ): Result[DecodedRawByteCode,string] =
  let data = db.get65(root, start, RawByteCode).valueOr:
    return err(error)
  data.decodeRawByteCode()

proc putRawAyteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
    codes: seq[(CodeHash,CodeItem)];
    peerID: Hash;
      ): Result[void,string] =
  db.put65(root, start, encodeRawByteCode(limit, codes, peerID), RawAccounts)

proc delRawByteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): Result[void,string] =
  db.del65(root, start, RawAccounts)

iterator walkRawByteCode*(db: MptAsmRef): WalkRawByteCode =
  for (key1,key2,value) in db.adb.rWalk65(RawByteCode.key65(), RawByteCode):
    let
      root = StateRoot(key1)
      start = key2.to(ItemKey)
      w = value.decodeRawByteCode().valueOr:
        var oops: WalkRawByteCode
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w.limit, w.codes, w.peerID, "")

iterator walkRawByteCode*(db: MptAsmRef, root: StateRoot): WalkRawByteCode =
  ## Variant of `walkRawAccounts()` for fixed `root`
  for (key1,key2,value) in db.adb.rWalk65(RawByteCode.key65(root), RawByteCode):
    if StateRoot(key1) != root:
      break
    let
      start = key2.to(ItemKey)
      w = value.decodeRawByteCode().valueOr:
        var oops: WalkRawByteCode
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w.limit, w.codes, w.peerID, "")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
