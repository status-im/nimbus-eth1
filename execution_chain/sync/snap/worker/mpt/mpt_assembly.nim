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
##
## Key/value download packet formats
## ---------------------------------
##
## * State context data:
##   + key33: <col, root>
##   + value: <hash, number, touch, tag, coverage>
##   where
##   + col:      `StateData`
##   + root:     `StateRoot`
##   + hash:     `BlockHash`
##   + number:   `BlockNumber`
##   + touch:    `Moment`
##   + tag:      `StateDataTag`
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
## * Storage slots:
##   + key97: <col, root, account, start>
##   + value: <limit, slot, proof, peerID>
##   where
##   + col:      `StoSlot`
##   + root:     `StateRoot`
##   * account:  `ItemKey`
##   + start:    `ItemKey`
##   + limit:    `ItemKey`
##   + slot:     `seq[StorageItem]`
##   + proof:    `seq[ProofNode]`
##   + peerID:   `Hash`
##
##
## Key/value KVT/MPT formats
## -------------------------
##
## * Accounts MPT:
##   + key33: <col, key>
##   + value: node
##   where
##   + col:       `AccKvt`
##   + key:       `seq[byte]`
##   * node:      `seq[byte]`
##
## * Storage MPTs:
##   + key65: <col, acc-path, key>
##   + value: node
##   where
##   + col:       `StoKvt`
##   + acc-path:  `Hash32`
##   + key:       `seq[byte]`
##   * node:      `seq[byte]`
##
## * Contract codes table:
##   + key33: <col, key>
##   + value: contract
##   where
##   + col:       `CodeKvt`
##   + key:       `seq[byte]`
##   * contract:  `seq[byte]`
##
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
##   + col:       `StoDnglKvt`
##   + acc-path:  `Hash32`
##   + key:       `seq[byte]`
##   * dngl-path: `seq[byte]`
##
## * Missing contract codes table:
##   + key33: <col, key>
##   + value: path
##   where
##   + col:       `CodeMissKvt`
##   + key:       `seq[byte]`
##   * path:      `seq[byte]`
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
  BoolResult* = Result[bool,string]
    ## Shortcut

  BlobResult* = Result[seq[byte],string]
    ## Shortcut

  PutResult* = Result[void,string]
    ## Shortcut

  DelResult* = Result[void,string]
    ## Shortcut

  MptAsmRef* = ref object
    adb: RocksDbReadWriteRef
    dir: Path
    dnglLock: int                                   # advisory lock
    cntrLock: int                                   # advisory lock

  MptAsmCol = enum
    AdminCol = 0                                    # currently unused

    StateData                                       # root -> block hash/number
    Accounts                                        # as fetched from network
    StoSlot                                         # ditto

    AccKvt                                          # accounts MPT
    StoKvt                                          # storage slots MPT
    CodeKvt                                         # contract codes table

    AccDnglKvt                                      # dangling acc nodes links
    StoDnglKvt                                      # dangling sto nodes links
    CodeMissKvt                                     # missing contract links

  StateDataTag* = enum
    Untagged = 0                                    # well, still a tag :)
    OnTrie                                          # assembled and merged
    PivotOnTrie                                     # ditto, state root here
    PivotMptAnalysed

  DecodedStateData* = tuple
    hash: BlockHash
    number: BlockNumber
    touch: Moment                                   # last data change
    tag: StateDataTag                               # state root also on trie
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


  CachedStateData* = tuple
    hash: BlockHash
    number: BlockNumber
    touch: Moment                                   # last data change
    tag: StateDataTag                               # how this record is used
    coverage: UInt256                               # account range coverage

  WalkStateData* = tuple
    root: StateRoot
    hash: BlockHash
    number: BlockNumber
    touch: Moment                                   # last data change
    tag: StateDataTag                               # how this record is used
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

  KvPair* = tuple
    key: seq[byte]
    value: seq[byte]

  KkvTriple = tuple
    ## Internal helper structure
    key1: seq[byte]
    key2: seq[byte]
    value: seq[byte]

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
    res.tag = StateDataTag(rd.read uint8)
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


template encodeStateData(
    hash: BlockHash;
    number: BlockNumber;
    touch: Moment;
    tag: StateDataTag;
    coverage: UInt256;
      ): untyped =
  var wrt = initRlpList 4
  wrt.append hash.to(Hash32)
  wrt.append number
  wrt.append max(touch.epochNanoSeconds(),0).uint64
  wrt.append tag.uint8
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

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc rGet(adb: RocksDbRef, key: openArray[byte]): BlobResult =
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

proc rClear(
    adb: RocksDbReadWriteRef;
    col: MptAsmCol;
    force = false;
      ): DelResult =
  const info = "mpt/clear: "
  let rit = adb.openIterator().valueOr:
    return err(info & "Iterator open error, col=" & $col & ", error=" & $error)
  defer: rit.close()

  var
    nErrors = 0
    key: seq[byte]

  rit.seekToKey(@[col.ord.byte])
  while rit.isValid():
    key.setLen(0)
    rit.key(proc(w: openArray[byte]) {.gcsafe, raises: [].} = key = @w)
    rit.next()

    if 0 < key.len:
      if col.ord.byte != key[0]:
        break

      adb.delete(key).isOkOr:
        if not force:
          return err(info & "Deletion failed" &
            ", col=" & $col & ", error=" & $error)
        nErrors.inc

  if 0 < nErrors:
    err(info & "Some deletions failed" &
      ", col=" & $col & ", nFailed=" & $nErrors)
  else:
    ok()

# ------------------------------------------------------------------------------
# Private generic iterators
# ------------------------------------------------------------------------------

proc kvPair(rit: RocksIteratorRef): KvPair =
  ## This helper must be provided as a separate function outside of any walk
  ## iterator, below. Otherwise the NIM compiler (version 2.2.4) might abort
  ## with an error
  ## ::
  ##   internal error: inconsistent environment type
  ##
  ## when compiling the execution layer.
  ##
  var kv: typeof(result)
  rit.key(proc(w: openArray[byte]) {.gcsafe, raises: [].} = kv.key = @w)
  rit.value(proc(w: openArray[byte]) {.gcsafe, raises: [].} = kv.value = @w)
  rit.next()
  kv

proc splitKey65(key: openArray[byte]; key1, key2: var Hash32): bool =
  ## As of NIM 2.2.10, this function is needed to reliably avoid internal
  ## code generation errors.
  if key.len == 65:
    (addr (key1.distinctBase)[0]).copyMem(addr key[1], 32)
    (addr (key2.distinctBase)[0]).copyMem(addr key[33], 32)
    return true
  # false

proc splitKey97(key: openArray[byte]; key1, key2, key3: var Hash32): bool =
  ## As of NIM 2.2.10, this function is needed to reliably avoid internal
  ## code generation errors.
  if key.len == 97:
    (addr (key1.distinctBase)[0]).copyMem(addr key[1], 32)
    (addr (key2.distinctBase)[0]).copyMem(addr key[33], 32)
    (addr (key3.distinctBase)[0]).copyMem(addr key[65], 32)
    return true
  # false

iterator colWalkAtLeast1(adb: RocksDbRef, pfx: openArray[byte]): KvPair =
  ## Walk over key-value pairs of the database for keys with the search
  ## head starting at postion `pfx[]`. The `pfx` argument must be length
  ## at least 1.
  ##
  const info = "mpt/colWalkAtLeast1: "
  block walkBody:
    let rit = adb.openIterator().valueOr:
      when extraTraceMessages:
        trace info & "Open error", error
      break walkBody
    defer: rit.close()

    let col = pfx[0]

    rit.seekToKey(pfx)
    while rit.isValid():
      let (key,value) = rit.kvPair()
      if key.len == 0:
        continue
      if col.ord.byte != key[0]:
        break
      if 1 < key.len:
        yield (key[1..^1], value)

iterator colWalkAtLeast33(adb: RocksDbRef, pfx: openArray[byte]): KkvTriple =
  ## Walk over key-value pairs of the database for keys with the search
  ## head starting at postion `pfx[]`. The `pfx` argument must be length
  ## at least 33.
  ##
  const info = "mpt/colWalkAtLeast33: "
  block walkBody:
    let rit = adb.openIterator().valueOr:
      when extraTraceMessages:
        trace info & "Open error", error
      break walkBody
    defer: rit.close()

    let
      col = pfx[0]
      pfx1 = pfx[1..32]

    rit.seekToKey(pfx)
    while rit.isValid():
      let (key,value) = rit.kvPair()
      if key.len == 0:
        continue
      if col.ord.byte != key[0]:
        break
      if 33 < key.len :
        var key1 = key[1..32]
        if key1 != pfx1:
          break
        yield (move key1, key[33..^1], value)

iterator colWalk33(
    adb: RocksDbRef;
    pfx: openArray[byte];
      ): tuple[key: Hash32, data: seq[byte]] =
  ## Walk over key-value pairs of the database for keys of length 33 where
  ## the search head is postioned at `pfx[0]`.
  ##
  const info = "mpt/colWalk33: "
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
      if key.len == 0:
        continue
      if col.ord.byte != key[0]:
        break
      if key.splitKey65(key1, key2):
        yield (move key1, move key2, value)

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
      if key.len == 0:
        continue
      if col.ord.byte != key[0]:
        break
      if key.splitKey97(key1, key2, key3):
        yield (key1, key2, key3, value)

# ------------------------------------------------------------------------------
# Private generic key/value helpers
# ------------------------------------------------------------------------------

template keyAtMost33(col: MptAsmCol; key: openArray[byte]): openArray[byte] =
  doAssert key.len < 33
  var keyData: array[33,byte]
  keyData[0] = col.ord
  (addr keyData[1]).copyMem(addr key[0], key.len)
  keyData.toOpenArray(0,key.len)

template getAtMost33(
    db: MptAsmRef;
    col: MptAsmCol;
    key: openArray[byte];
      ): untyped =
  db.adb.rGet(col.keyAtMost33 key)

template putAtMost33(
    db: MptAsmRef;
    col: MptAsmCol;
    key: openArray[byte];
    data: openArray[byte];
      ): untyped =
  if key.len == 0:
    PutResult.err("zero key not allowed")
  else:
    db.adb.rPut(col.keyAtMost33 key, data)

template delAtMost33(
    db: MptAsmRef;
    col: MptAsmCol;
    key: openArray[byte];
      ): untyped =
  db.adb.rDel col.keyAtMost33(key)

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

template getAtMost65(
    db: MptAsmRef;
    col: MptAsmCol;
    key1: untyped;
    key2: openArray[byte];
      ): untyped =
  db.adb.rGet col.keyAtMost65(key1, key2)

template putAtMost65(
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

template delAtMost65(
    db: MptAsmRef;
    col: MptAsmCol;
    key1: untyped;
    key2: openArray[byte];
      ): untyped =
  db.adb.rDel col.keyAtMost65(key1, key2)

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
  db.adb.rGet col.key65(root, startHash)

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
  db.adb.rDel col.key65(root, startHash)

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
      ): Result[CachedStateData,string] =
  let data = db.get33(StateData, root).valueOr:
    return err(error)
  data.decodeStateData()

proc putStateData*(
    db: MptAsmRef;
    root: StateRoot;
    data: CachedStateData;
      ): PutResult =
  db.put33(StateData, root, encodeStateData(
    data.hash, data.number, data.touch, data.tag, data.coverage))

proc putStateData*(
    db: MptAsmRef;
    root: StateRoot;
    hash: BlockHash;
    number: BlockNumber;
    touch: Moment;
    tag: StateDataTag;
    coverage: UInt256;
      ): PutResult =
  db.put33(StateData, root, encodeStateData(hash, number, touch, tag, coverage))

proc putStateData*(
    db: MptAsmRef;
    state: WalkStateData;
      ): PutResult =
  db.put33(StateData, state.root,
    encodeStateData(
      state.hash, state.number, state.touch, state.tag, state.coverage))

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
    yield (StateRoot(key), w.hash, w.number, w.touch, w.tag, w.coverage, "")

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

proc clearAccounts*(db: MptAsmRef): DelResult =
  db.adb.rClear(Accounts)

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

proc clearStoSlot*(db: MptAsmRef): DelResult =
  db.adb.rClear(StoSlot)

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

# ========================

proc hasAccKvt*(db: MptAsmRef; key: openArray[byte]): BoolResult =
  var data = db.getAtMost33(AccKvt, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getAccKvt*(db: MptAsmRef; key: openArray[byte]): BlobResult =
  var data = db.getAtMost33(AccKvt, key).valueOr:
    return err(error)
  ok(move data)

proc putAccKvt*(db: MptAsmRef; nodes: openArray[KnPair]): PutResult =
  for w in nodes:
    db.putAtMost33(AccKvt, w.key, w.node).isOkOr:
      return err(error)
  ok()

proc delAccKvt*(db: MptAsmRef, key: openArray[byte]): DelResult =
  db.delAtMost33(AccKvt, key)

proc clearAccKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(AccKvt)

iterator walkAccKvt*(db: MptAsmRef): KnPair =
  for (key,node) in db.adb.colWalkAtLeast1 @[byte AccKvt]:
    yield (key,node)

# -------------

proc hasStoKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): BoolResult =
  let data = db.getAtMost65(StoKvt, acc, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getStoKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): BlobResult =
  var data = db.getAtMost65(StoKvt, acc, key).valueOr:
    return err(error)
  ok(move data)

proc putStoKvt*(
    db: MptAsmRef;
    acc: Hash32;
    nodes: openArray[KnPair];
      ): PutResult =
  for w in nodes:
    db.putAtMost65(StoKvt, acc, w.key, w.node).isOkOr:
      return err(error)
  ok()

proc delStoKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): DelResult =
  db.delAtMost65(StoKvt, acc, key)

proc clearStoKvt*(db: MptAsmRef, acc: Hash32): DelResult =
  for (key1, key2,_) in db.adb.colWalkAtLeast33 key33(StoKvt, acc):
    db.delAtMost65(StoKvt, key1, key2).isOkOr:
      return err(error)
  ok()

proc clearStoKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(StoKvt)

iterator walkStoKvt*(db: MptAsmRef, acc: Hash32): KkpTriple =
  for (key1, key2, path) in db.adb.colWalkAtLeast33 key33(StoKvt, acc):
    yield (key1, key2, path)

iterator walkStoKvt*(db: MptAsmRef): KkpTriple =
  for (key,path) in db.adb.colWalkAtLeast1 @[byte StoKvt]:
    if 32 < key.len:
      yield (key[0..31], key[32..^1], path)

# -------------

proc hasCodeKvt*(db: MptAsmRef; hash: Hash32): BoolResult =
  let data = db.get33(CodeKvt, hash).valueOr:
    return err(error)
  ok(0 < data.len)

proc getCodeKvt*(db: MptAsmRef; hash: Hash32): BlobResult =
  var data = db.get33(CodeKvt, hash).valueOr:
    return err(error)
  ok(move data)

proc putCodeKvt*(db: MptAsmRef; cdHash: CodeHash; data: CodeItem): PutResult =
  db.put33(CodeKvt, cdHash.to(Hash32), data.to(seq[byte]))

proc putCodeKvt*(db: MptAsmRef; contracts: openArray[KvPair]): PutResult =
  for w in contracts:
    db.put33(CodeKvt, w.key, w.value).isOkOr:
      return err(error)
  ok()

proc delCodeKvt*(db: MptAsmRef, hash: Hash32): DelResult =
  db.del33(CodeKvt, hash)

proc clearCodeKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(CodeKvt)

iterator walkCodeKvt*(db: MptAsmRef): KvPair =
  for (key,value) in db.adb.colWalkAtLeast1 @[byte CodeKvt]:
    yield (key,value)

# -------------

proc hasAccDnglKvt*(db: MptAsmRef; key: openArray[byte]): BoolResult =
  let data = db.getAtMost33(AccDnglKvt, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getAccDnglKvt*(db: MptAsmRef; key: openArray[byte]): BlobResult =
  var data = db.getAtMost33(AccDnglKvt, key).valueOr:
    return err(error)
  ok(move data)

proc putAccDnglKvt*(db: MptAsmRef; key, path: openArray[byte]): PutResult =
  db.putAtMost33(AccDnglKvt, key, path)

proc putAccDnglKvt*(db: MptAsmRef, kvp: openArray[KpPair]): PutResult =
  for w in kvp:
    db.putAtMost33(AccDnglKvt, w.key, w.path).isOkOr:
      return err(error)
  ok()

proc delAccDnglKvt*(db: MptAsmRef, key: openArray[byte]): DelResult =
  db.delAtMost33(AccDnglKvt, key)

proc delAccDnglKvt*(db: MptAsmRef, keys: openArray[seq[byte]]): DelResult =
  for key in keys:
    db.delAtMost33(AccDnglKvt, key).isOkOr:
      return err(error)
  ok()

proc clearAccDnglKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(AccDnglKvt)

iterator walkAccDnglKvt*(db: MptAsmRef): KpPair =
  for (key,path) in db.adb.colWalkAtLeast1 @[byte AccDnglKvt]:
    yield (key,path)

# -------------

proc hasStoDnglKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): BoolResult =
  let data = db.getAtMost65(StoDnglKvt, acc, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getStoDnglKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
      ): BlobResult =
  var data = db.getAtMost65(StoDnglKvt, acc, key).valueOr:
    return err(error)
  ok(move data)

proc putStoDnglKvt*(
    db: MptAsmRef;
    acc: Hash32;
    key: openArray[byte];
    data: openArray[byte];
      ): PutResult =
  db.putAtMost65(StoDnglKvt, acc, key, data)

proc putStoDnglKvt*(
    db: MptAsmRef;
    acc: Hash32;
    kvp: openArray[KpPair];
      ): PutResult =
  for w in kvp:
    db.putAtMost65(StoDnglKvt, acc, w.key, w.path).isOkOr:
      return err(error)
  ok()

proc delStoDnglKvt*(
    db: MptAsmRef,
    acc: Hash32;
    key: openArray[byte];
      ): DelResult =
  db.delAtMost65(StoDnglKvt, acc, key)

proc delStoDnglKvt*(
    db: MptAsmRef,
    acc: Hash32;
    keys: openArray[seq[byte]];
      ): DelResult =
  for key in keys:
    db.delAtMost65(StoDnglKvt, acc, key).isOkOr:
      return err(error)
  ok()

proc clearStoDnglKvt*(db: MptAsmRef, acc: Hash32): DelResult =
  for (key1, key2,_) in db.adb.colWalkAtLeast33 key33(StoDnglKvt, acc):
    db.delAtMost65(StoDnglKvt, key1, key2).isOkOr:
      return err(error)
  ok()

proc clearStoDnglKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(StoDnglKvt)

iterator walkStoDnglKvt*(db: MptAsmRef, acc: Hash32): KkpTriple =
  for (key1, key2, path) in db.adb.colWalkAtLeast33 key33(StoDnglKvt, acc):
    yield (key1, key2, path)

iterator walkStoDnglKvt*(db: MptAsmRef): KkpTriple =
  for (key,path) in db.adb.colWalkAtLeast1 @[byte StoDnglKvt]:
    if 32 < key.len:
      yield (key[0..31], key[32..^1], path)

# -------------

proc hasCodeMissKvt*(db: MptAsmRef; key: openArray[byte]): BoolResult =
  let data = db.getAtMost33(CodeMissKvt, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getCodeMissKvt*(db: MptAsmRef; key: openArray[byte]): BlobResult =
  var data = db.getAtMost33(CodeMissKvt, key).valueOr:
    return err(error)
  ok(move data)

proc putCodeMissKvt*(db: MptAsmRef; key, path: openArray[byte]): PutResult =
  db.putAtMost33(CodeMissKvt, key, path)

proc putCodeMissKvt*(db: MptAsmRef; w: KpPair): PutResult =
  db.putAtMost33(CodeMissKvt, w.key, w.path)

proc putCodeMissKvt*(
    db: MptAsmRef;
    kvp: openArray[KpPair];
      ): PutResult =
  for w in kvp:
    db.putAtMost33(CodeMissKvt, w.key, w.path).isOkOr:
      return err(error)
  ok()

proc delCodeMissKvt*(db: MptAsmRef, key: openArray[byte]): DelResult =
  db.delAtMost33(CodeMissKvt, key)

proc delCodeMissKvt*(db: MptAsmRef, keys: openArray[seq[byte]]): DelResult =
  for key in keys:
    db.delAtMost33(CodeMissKvt, key).isOkOr:
      return err(error)
  ok()

proc clearCodeMissKvt*(db: MptAsmRef): DelResult =
  db.adb.rClear(CodeMissKvt)

iterator walkCodeMissKvt*(db: MptAsmRef): KpPair =
  for (key, path) in db.adb.colWalkAtLeast1 @[byte CodeMissKvt]:
    yield (key, path)

# -------------

template withDnglAccSto*(db: MptAsmRef, code: untyped): untyped =
  ## Run `code` while advisory lock is set. The only use of this lock is
  ## to make sure that the `hasDnglAccSto()` returns empty only if
  ##
  ## * there is no `withDnglAccSto()` code active, and
  ## * the dangling `*AccDnglKvt` or `*StoDnglKvt` tables are empty.
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
