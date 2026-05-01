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
## * StateData:
##   + key33: <col, root>
##   + value: <hash, number, touch, onTrie, coverage>
##   where
##   + col:      `Accounts`
##   + root:     `StateRoot`
##   + hash:     `BlockHash`
##   + number:   `BlockNumber`
##   + touch:    `Moment`
##   + onTrie:   `bool`
##   * coverage: `UInt256`
##
## * Accounts:
##   + key65: <col, root, start>
##   + value: <limit, accounts, proof, peerID>
##   where
##   + col:      `Accounts`
##   + root:     `StateRoot`
##   + start:    `ItemKey`
##   + limit:    `ItemKey`
##   + accounts: `seq[SnapAccount]`
##   + proof:    `seq[ProofNode]`
##   + peerID:   `Hash`
##
## * StoSlot:
##   + key97: <col, root, account, start>
##   + value: <limit, slot, proof, peerID>
##   where
##   + col:      `Accounts`
##   + root:     `StateRoot`
##   * account:  `ItemKey`
##   + start:    `ItemKey`
##   + limit:    `ItemKey`
##   + slot:     `seq[StorageItem]`
##   + proof:    `seq[ProofNode]`
##   + peerID:   `Hash`
##
## * ByteCode:
##   + key65: <col, root, start>
##   + value: <limit, code, peerID>
##   where
##   + col:      `ByteCodes`
##   + root:     `StateRoot`
##   * start:    `ItemKey`
##   + limit:    `ItemKey`
##   + codes:    `seq[(CodeHash,CodeItem)]`
##   + peerID:   `Hash`
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
  EmptyProof = seq[ProofNode].default

  extraTraceMessages = true
    ## Enable additional logging noise

type
  PutResult* = Result[void,string]
    ## Shortcut

  DelResult* = Result[void,string]
    ## Shortcut

  MptAsmRef* = ref object
    adb: RocksDbReadWriteRef
    dir: Path

  MptAsmCol = enum
    AdminCol = 0                                    # currently unused

    StateData                                       # root -> block hash/number
    Accounts                                        # as fetched from network
    StoSlot                                         # ditto
    ByteCode                                        # ditto

    AccTrie                                         # hash -> node mapping
    StoTrie                                         # hash -> node mapping
    CodeList                                        # hash -> code mapping

  DecodedStateData* = tuple
    hash: BlockHash
    number: BlockNumber
    touch: Moment                                   # last data change
    onTrie: bool                                    # state root also on trie
    coverage: UInt256                               # account range coverage

  DecodedAccounts* = tuple
    limit: ItemKey
    accounts: seq[SnapAccount]
    proof: seq[ProofNode]
    peerID: Hash

  DecodedStoSlot* = tuple
    limit: ItemKey
    slot: seq[StorageItem]
    proof: seq[ProofNode]
    peerID: Hash

  DecodedByteCode* = tuple
    limit: ItemKey
    codes: seq[(CodeHash,CodeItem)]
    peerID: Hash


  WalkStateData* = tuple
    root: StateRoot
    hash: BlockHash
    number: BlockNumber
    touch: Moment                                   # last data change
    onTrie: bool                                    # state root also on trie
    coverage: UInt256                               # account range coverage
    error: string

  WalkAccounts* = tuple
    root: StateRoot
    start: ItemKey
    limit: ItemKey
    accounts: seq[SnapAccount]
    proof: seq[ProofNode]
    peerID: Hash
    error: string

  WalkStoSlot* = tuple
    root: StateRoot
    account: ItemKey
    start: ItemKey                                  # `0` unless incomplete
    limit: ItemKey                                  # `high()` unless incomplete
    slot: seq[StorageItem]
    proof: seq[ProofNode]                           # Prof for `slot` (if any)
    peerID: Hash
    error: string

  WalkByteCode* = tuple
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

proc decodeStateData(data: seq[byte]): Result[DecodedStateData,string] =
  const info = "decodeStateData"
  var
    rd = data.rlpFromBytes
    res: DecodedStateData
  try:
    rd.tryEnterList()
    res.hash = rd.read(Hash32).to(BlockHash)
    res.number = rd.read(BlockNumber)
    res.touch = Moment.fromNow(rd.read(uint64).int64.nanoseconds)
    res.onTrie = rd.read(bool)
    res.coverage = rd.read(UInt256)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeAccounts(data: seq[byte]): Result[DecodedAccounts,string] =
  const info = "decodeAccounts"
  var
    rd = data.rlpFromBytes
    res: DecodedAccounts
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.accounts = rd.read(seq[SnapAccount])
    res.proof = rd.read(seq[ProofNode])
    res.peerID = cast[Hash](rd.read uint)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeStoSlot(data: seq[byte]): Result[DecodedStoSlot,string] =
  const info = "decodeStoSlot"
  var
    rd = data.rlpFromBytes
    res: DecodedStoSlot
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.slot = rd.read(seq[StorageItem])
    res.proof = rd.read(seq[ProofNode])
    res.peerID = cast[Hash](rd.read uint)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeByteCode(data: seq[byte]): Result[DecodedByteCode,string] =
  const info = "decodeByteCode"
  var
    rd = data.rlpFromBytes
    res: DecodedByteCode
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.codes = rd.read(seq[(CodeHash,CodeItem)])
    res.peerID = cast[Hash](rd.read uint)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)


template encodeStateData(
    hash: BlockHash;
    number: BlockNumber;
    touch: Moment;
    onTrie: bool;
    coverage: UInt256;
      ): untyped =
  var wrt = initRlpList 4
  wrt.append hash.to(Hash32)
  wrt.append number
  wrt.append max(touch.epochNanoSeconds(),0).uint64
  wrt.append onTrie
  wrt.append coverage
  wrt.finish()

template encodeAccounts(
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

template encodeStoSlot(
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

template encodeByteCode(
    limit: ItemKey;
    codes: seq[(CodeHash,CodeItem)];
    peerID: Hash;
      ): untyped =
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
      ): PutResult =
  const info = "mpt/put: "
  adb.put(key, data).isOkOr:
    when extraTraceMessages:
      trace info & "failed", key=key.toHex, `error`=error
    return err(info & error)
  ok()

proc rDel(adb: RocksDbReadWriteRef; key: openArray[byte]): DelResult =
  const info = "mpt/del: "
  adb.delete(key).isOkOr:
    when extraTraceMessages:
      trace info & "failed", key=key.toHex, `error`=error
    return err(info & error)
  ok()

proc kvPair(rit: RocksIteratorRef): (seq[byte],seq[byte]) =
  ## This helper must be provided as a separate function outside of any walk
  ## iterator, below. Otherwise the NIM compiler (version 2.2.4) might abort
  ## with an error
  ## ::
  ##   internal error: inconsistent environment type
  ##
  ## when compiling the execution layer.
  ##
  var kv: typeof(result)
  rit.key(proc(w: openArray[byte]) {.gcsafe, raises: [].} = kv[0] = @w)
  rit.value(proc(w: openArray[byte]) {.gcsafe, raises: [].} = kv[1] = @w)
  rit.next()
  kv

iterator colWalk33(
    adb: RocksDbRef;
    pfx: openArray[byte];
      ): tuple[key: Hash32, data: seq[byte]] =
  ## Walk over key-value pairs of the database for keys of length 33 where
  ## the search head is postioned at `pfx[0]`.
  ##
  const info = "mpt/colWalk63: "
  block walkBody:
    let rit = adb.openIterator().valueOr:
      when extraTraceMessages:
        trace info & "Open error", error
      break walkBody
    defer: rit.close()

    let col = pfx[0]
    var key1: Hash32

    rit.seekToKey(pfx)
    while rit.isValid():
      let (key,value) = rit.kvPair()
      if 0 < key.len and col.ord.byte != key[0]:
        break
      if key.len == 33:
        (addr (key1.distinctBase)[0]).copyMem(addr key[1], 32)
        yield (key1, value)

iterator colWalk65(
    adb: RocksDbRef;
    pfx: openArray[byte];
      ): tuple[key1, key2: Hash32, data: seq[byte]] =
  ## Variant of `colWalk33` for 65 byte keys, staying at column `pfx[0]`
  ##
  const info = "mpt/colWalk65: "
  block walkBody:
    let rit = adb.openIterator().valueOr:
      when extraTraceMessages:
        trace info & "Open error", error
      break walkBody
    defer: rit.close()

    let col = pfx[0]
    var key1, key2: Hash32

    rit.seekToKey(pfx)
    while rit.isValid():
      let (key,value) = rit.kvPair()
      if 0 < key.len and col.ord.byte != key[0]:
        break
      if key.len == 65:
        (addr (key1.distinctBase)[0]).copyMem(addr key[1], 32)
        (addr (key2.distinctBase)[0]).copyMem(addr key[33], 32)
        yield (key1, key2, value)

iterator colWalk97(
    adb: RocksDbRef;
    pfx: openArray[byte];
      ): tuple[key1, key2, key3: Hash32, data: seq[byte]] =
  ## Variant of `colWalk33` for 97 byte keys, staying at column `pfx[0]`
  ##
  const info = "mpt/colWalk97: "
  block walkBody:
    let rit = adb.openIterator().valueOr:
      when extraTraceMessages:
        trace info & "Open error", error
      break walkBody
    defer: rit.close()

    let col = pfx[0]
    var key1, key2, key3: Hash32

    rit.seekToKey(pfx)
    while rit.isValid():
      let (key,value) = rit.kvPair()
      if 0 < key.len and col.ord.byte != key[0]:
        break
      if key.len == 97:
        (addr (key1.distinctBase)[0]).copyMem(addr key[1], 32)
        (addr (key2.distinctBase)[0]).copyMem(addr key[33], 32)
        (addr (key3.distinctBase)[0]).copyMem(addr key[65], 32)
        yield (key1, key2, key3, value)

# --------------

template keyAtMost33(col: MptAsmCol; key: seq[byte]): openArray[byte] =
  doAssert key.len < 33
  var keyData: array[33,byte]
  keyData[0] = col.ord
  (addr keyData[1]).copyMem(addr key[0], key.len)
  keyData.toOpenArray(0,key.len)

template getAtMost33(db: MptAsmRef; col: MptAsmCol; key: seq[byte]): untyped =
  db.adb.rGet(col.keyAtMost33 key)

template putAtMost33(
    db: MptAsmRef;
    col: MptAsmCol;
    key: seq[byte];
    data: openArray[byte];
      ): untyped =
  if key.len == 0:
    PutResult.err("zero key not allowed")
  else:
    db.adb.rPut(col.keyAtMost33 key, data)

template delAtMost33(db: MptAsmRef; col: MptAsmCol; key: seq[byte]): untyped =
  db.adb.rDel(col.keyAtMost33 key)

# --------------

template key33(col: MptAsmCol; key1: untyped): openArray[byte] =
  var key: array[33,byte]
  key[0] = col.ord
  (addr key[1]).copyMem(addr (key1.distinctBase)[0], 32)
  key.toOpenArray(0,32)

template key33(col: MptAsmCol): openArray[byte] =
  var key: array[33,byte]
  key[0] = col.ord
  key.toOpenArray(0,32)

template get33(db: MptAsmRef; col: MptAsmCol; key1: untyped): untyped =
  db.adb.rGet(col.key33 key1)

template put33(
    db: MptAsmRef;
    col: MptAsmCol;
    key1: untyped;
    data: openArray[byte];
      ): untyped =
  db.adb.rPut(col.key33 key1, data)

template del33(db: MptAsmRef; col: MptAsmCol; key1: untyped): untyped =
  db.adb.rDel(col.key33 key1)

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
    col: MptAsmCol;
    root: StateRoot;
    start: ItemKey;
      ): untyped =
  let startHash = start.to(Hash32)
  db.adb.rGet(col.key65(root, startHash))

template put65(
    db: MptAsmRef;
    col: MptAsmCol;
    root: StateRoot;
    start: ItemKey;
    data: openArray[byte];
      ): untyped =
  let startHash = start.to(Hash32)
  db.adb.rPut(col.key65(root, startHash), data)

template del65(
    db: MptAsmRef;
    col: MptAsmCol;
    root: StateRoot;
    start: ItemKey;
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
    col: MptAsmCol;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
      ): untyped =
  let
    startHash = start.to(Hash32)
    account = acc.to(Hash32)
  db.adb.rGet(col.key97(root, account, startHash))

template put97(
    db: MptAsmRef;
    col: MptAsmCol;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
    data: openArray[byte];
      ): untyped =
  let
    startHash = start.to(Hash32)
    account = acc.to(Hash32)
  db.adb.rPut(col.key97(root, account, startHash), data)

template del97(
    db: MptAsmRef;
    col: MptAsmCol;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
      ): untyped =
  let
    startHash = start.to(Hash32)
    account = acc.to(Hash32)
  db.adb.rDel(col.key97(root, account, startHash))

# ------------------------------------------------------------------------------
# Private constructor helpers
# ------------------------------------------------------------------------------

proc closeDb(db: MptAsmRef) =
  if not db.adb.isNil:
    db.adb.close()
    db.adb = RocksDbReadWriteRef(nil)

proc openDb(db: MptAsmRef; info: static[string]): bool =
  db.adb = db.dir.distinctBase.openRocksDb().valueOr:
    error info & ": Cannot create assembly DB", dir=db.dir, `error`=error
    return false
  true

proc newDbFolder(db: MptAsmRef; info: static[string]): bool =
  if db.dir.dirExists:
    let bakDir = Path(db.dir.distinctBase & "~")
    block backupOldFolder:
      var excpt = ""
      try:
        bakDir.removeDir()
        db.dir.moveDir bakDir
        break backupOldFolder
      except OSError as e:
        excpt = $e.name & "(" & e.msg & ")"
      except IOError as e:
        excpt = $e.name & "(" & e.msg & ")"
      error info & ": Cannot backup DB folder", dir=db.dir, bakDir, excpt
      return false

  block createSnapFolder:
    var excpt = ""
    try:
      db.dir.createDir()
      break createSnapFolder
    except OSError as e:
      excpt = $e.name & "(" & e.msg & ")"
    except IOError as e:
      excpt = $e.name & "(" & e.msg & ")"
    error info & ": Cannot create assembly folder", dir=db.dir, excpt
    return false

  true

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc close*(db: MptAsmRef, wipe = false) =
  ## Close database unless done yet. If the argument `wipe` is set
  ## `true`, then the database will be physically deleted.
  ##
  db.closeDb()
  if wipe:
    try:
      db.dir.removeDir()

      # Remove the base folder if it is empty
      block done:
        for w in db.dir.parentDir.walkDirRec():
          # Ignore backup files
          let p = w.distinctBase
          if 0 < p.len and p[^1] != '~':
            break done
        db.dir.removeDir()
    except CatchableError:
      discard

proc clear*(db: MptAsmRef; info: static[string]): bool =
  ## Close database and move it to a backup directory, then re-open a new
  ## database. Any previous backup database will be deleted.
  ##
  ## This function returns the argument true if database backup and
  ## re-open succeeded, and `false` otherwise.
  ##
  db.closeDb()
  db.newDbFolder(info) and db.openDb(info)

proc init*(
    T: type MptAsmRef;
    baseDir: string;
    info: static[string];
      ): Opt[T] =
  ## Create or open an existing database. If the ergument `newDb` is set
  ## `false`, the database is opened. Otherwise, `MptAsmRef.init(dir,true)`
  ## is roughly equivalent to
  ## ::
  ##   let db = MptAsmRef.init(dir,false).expect "value"
  ##   discard db.clear()
  ##
  if baseDir.len == 0:
    error info & ": No base directory for assembly DB"

  else:
    let db = T(dir: Path(baseDir) / Path(snapAsmFolder))
    if db.openDb(info):
      return ok db

  err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getStateData*(
    db: MptAsmRef;
    root: StateRoot;
      ): Result[(BlockHash,BlockNumber,Moment,bool,UInt256),string] =
  let data = db.get33(StateData, root).valueOr:
    return err(error)
  data.decodeStateData()

proc putStateData*(
    db: MptAsmRef;
    root: StateRoot;
    hash: BlockHash;
    number: BlockNumber;
    touch: Moment;
    onTrie: bool;
    coverage: UInt256;
      ): PutResult =
  db.put33(StateData, root,
           encodeStateData(hash, number, touch, onTrie, coverage))

proc delStateData*(db: MptAsmRef; root: StateRoot): DelResult =
  db.del33(StateData, root)

iterator walkStateData*(db: MptAsmRef): WalkStateData =
  for (key,value) in db.adb.colWalk33 StateData.key33():
    let w = value.decodeStateData().valueOr:
        var oops: WalkStateData
        oops.root = StateRoot(key)
        oops.error = error
        yield oops
        continue
    yield (StateRoot(key), w.hash, w.number, w.touch, w.onTrie, w.coverage, "")

# -------------

proc getAccounts*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): Result[DecodedAccounts,string] =
  let data = db.get65(Accounts, root, start).valueOr:
    return err(error)
  data.decodeAccounts()

proc putAccounts*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
    accounts: seq[SnapAccount];
    proof: seq[ProofNode];
    peerID: Hash;
      ): PutResult =
  db.put65(
    Accounts, root, start, encodeAccounts(limit, accounts, proof, peerID))

proc delAccounts*(db: MptAsmRef; root: StateRoot; start: ItemKey): DelResult =
  db.del65(Accounts, root, start)

iterator walkAccounts*(db: MptAsmRef): WalkAccounts =
  for (key1,key2,value) in db.adb.colWalk65 Accounts.key65():
    let
      root = StateRoot(key1)
      start = key2.to(ItemKey)
      w = value.decodeAccounts().valueOr:
        var oops: WalkAccounts
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w.limit, w.accounts, w.proof, w.peerID, "")

iterator walkAccounts*(db: MptAsmRef, root: StateRoot): WalkAccounts =
  ## Variant of `walkAccounts()` for fixed `root`
  for (key1,key2,value) in db.adb.colWalk65 Accounts.key65(root):
    if StateRoot(key1) != root:
      break
    let
      start = key2.to(ItemKey)
      w = value.decodeAccounts().valueOr:
        var oops: WalkAccounts
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w.limit, w.accounts, w.proof, w.peerID, "")

# -------------

proc getStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    account: ItemKey;
    start: ItemKey;
      ): Result[DecodedStoSlot,string] =
  let data = db.get97(StoSlot, root, account, start).valueOr:
    return err(error)
  data.decodeStoSlot()

proc putStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
    limit: ItemKey;
    slot: seq[StorageItem];
    proof: seq[ProofNode];
    peerID: Hash;
      ): PutResult =
  db.put97(
    StoSlot, root, acc, start, encodeStoSlot(limit, slot, proof, peerID))

proc putStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    slot: seq[StorageItem];
    peerID: Hash;
      ): PutResult =
  db.put97(
    StoSlot, root, acc, low(ItemKey),
    encodeStoSlot(high(ItemKey), slot, EmptyProof, peerID))

proc delStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
      ): DelResult =
  db.del97(StoSlot, root, acc, start)

iterator walkStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
      ): WalkStoSlot =
  ## Variant of `walkStoSlot()` for fixed `root`
  let aHash = acc.to(Hash32)
  for (k1,k2,k3,val) in db.adb.colWalk97 StoSlot.key97(root,aHash):
    if k1.to(StateRoot) != root or
       k2.to(ItemKey) != acc:
      break
    let
      start = k3.to(ItemKey)
      w = val.decodeStoSlot().valueOr:
        var oops: WalkStoSlot
        oops.root = root
        oops.account = acc
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, acc, start, w.limit, w.slot, w.proof, w.peerID, "")

# -------------

proc getByteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
      ): Result[DecodedByteCode,string] =
  let data = db.get65(ByteCode, root, start).valueOr:
    return err(error)
  data.decodeByteCode()

proc putByteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
    codes: seq[(CodeHash,CodeItem)];
    peerID: Hash;
      ): PutResult =
  db.put65(ByteCode, root, start, encodeByteCode(limit, codes, peerID))

proc delByteCode*(db: MptAsmRef; root: StateRoot; start: ItemKey): DelResult =
  db.del65(Accounts, root, start)

iterator walkByteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): WalkByteCode =
  ## Variant of `walkAccounts()` for fixed `root` and `start` account
  let startHash = start.to(Hash32)
  for (key1,key2,value) in db.adb.colWalk65 ByteCode.key65(root,startHash):
    if StateRoot(key1) != root:
      break
    let
      start2 = key2.to(ItemKey)
      w = value.decodeByteCode().valueOr:
        var oops: WalkByteCode
        oops.root = root
        oops.start = start2
        oops.error = error
        yield oops
        continue
    yield (root, start2, w.limit, w.codes, w.peerID, "")

# -------------

proc getAccTrie*(db: MptAsmRef; key: seq[byte]): seq[byte] =
  db.getAtMost33(AccTrie, key).isErrOr:
    return value
  # @[]

proc putAccTrie*(db: MptAsmRef; nodes: seq[(seq[byte],seq[byte])]): PutResult =
  for (key,val) in nodes:
    db.putAtMost33(AccTrie, key, val).isOkOr:
      return err(error)
  ok()

proc delAccTrie*(db: MptAsmRef, key: seq[byte]): DelResult =
  db.delAtMost33(AccTrie, key)

# -------------

proc getStoTrie*(db: MptAsmRef; key: seq[byte]): seq[byte] =
  db.getAtMost33(StoTrie, key).isErrOr:
    return value
  # @[]

proc putStoTrie*(db: MptAsmRef; nodes: seq[(seq[byte],seq[byte])]): PutResult =
  for (key,val) in nodes:
    db.putAtMost33(StoTrie, key, val).isOkOr:
      return err(error)
  ok()

proc delStoTrie*(db: MptAsmRef, key: seq[byte]): DelResult =
  db.delAtMost33(StoTrie, key)

# -------------

proc getCodeList*(db: MptAsmRef; hash: Hash32): seq[byte] =
  db.get33(CodeList, hash).isErrOr:
    return value
  # @[]

proc putCodeList*(db: MptAsmRef; cdHash: CodeHash; data: CodeItem): PutResult =
  db.put33(CodeList, cdHash.to(Hash32), data.to(seq[byte]))

proc delCodeList*(db: MptAsmRef, hash: Hash32): DelResult =
  db.del33(CodeList, hash)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
