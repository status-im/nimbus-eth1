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
## Reference headers
## ------------------
##
## * headers:
##   + key9: <col, number>
##   + value: <header>
##   where
##   + col:      `cHeader`
##   + number:   `BlockNumber`
##   + header:   `Header`
##   + touch:    `Moment`
##   + tag:      `StateDataTag`
##   * coverage: `UInt256`
##
##
## Key/value download packet formats
## ---------------------------------
##
## * State context data:
##   + key33: <col, root>
##   + value: <hash, number, touch, tag, coverage>
##   where
##   + col:      `cStateData`
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
##   + col:      `cAccount`
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
##   + col:      `cStoSlot`
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
##   + col:      `cByteCode`
##   + root:     `StateRoot`
##   * start:    `ItemKey`
##   + limit:    `ItemKey`
##   + codes:    `seq[(CodeHash,CodeItem)]`
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
  pkg/[chronicles, chronos, eth/common, results, rocksdb],
  pkg/stew/[byteutils, endians2],
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

  HeaderResult* = Result[Header,string]
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
    cAdminCol = 0                                   # currently unused
    cHeader                                         # header chain by block num

    cStateData                                      # root -> block hash/number
    cAccount                                        # as fetched from network
    cStoSlot                                        # ditto
    cByteCode                                       # ditto

    cAccKvt                                         # accounts MPT
    cStoKvt                                         # storage slots MPT
    cCodeKvt                                        # contract codes table

    cAccDnglKvt                                     # dangling acc nodes links
    cStoDnglKvt                                     # dangling sto nodes links
    cCodeMissKvt                                    # missing contract links

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

  DecodedAccount* = tuple
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

  WalkAccount* = tuple
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

  WalkHeader* = tuple
    header: Header
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

func decodeAccount(data: seq[byte]): Result[DecodedAccount,string] =
  const info = "decodeAccount"
  var
    rd = data.rlpFromBytes
    res: DecodedAccount
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

func decodeHeader(data: seq[byte]): Result[Header,string] =
  const info = "decodeStoSlot"
  var
    res: Header
  try:
    res = rlp.decode(data, Header)
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

template encodeAccount(
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

template encodeHeader(
    header: Header;
      ): untyped =
  rlp.encode header

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

iterator colWalk9(
    adb: RocksDbRef;
    pfx: openArray[byte];
      ): tuple[key: uint64, data: seq[byte]] =
  ## Walk over key-value pairs of the database for keys of length 9 where
  ## the search head is postioned at `pfx[0]`.
  ##
  const info = "mpt/colWalk9: "
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
      if 0 < key.len and col.ord.byte != key[0]:
        break
      if key.len == 9:
        yield (uint64.fromBytesBE key.toOpenArray(1, 8), value)

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

template key9(col: MptAsmCol; key1: uint64): openArray[byte] =
  var keyData: array[9,byte]
  let key1Data = key1.toBytesBE()
  keyData[0] = col.ord
  (addr keyData[1]).copyMem(addr key1Data[0], 8)
  keyData.toOpenArray(0,8)

template key9(col: MptAsmCol): openArray[byte] =
  var key: array[9,byte]
  key[0] = col.ord
  key.toOpenArray(0,8)

template get9(db: MptAsmRef; col: MptAsmCol; key1: uint64): untyped =
  db.adb.rGet(col.key9 key1)

template put9(
    db: MptAsmRef;
    col: MptAsmCol;
    key1: uint64;
    data: openArray[byte];
      ): untyped =
  db.adb.rPut(col.key9 key1, data)

template del9(db: MptAsmRef; col: MptAsmCol; key1: uint64): untyped =
  db.adb.rDel(col.key9 key1)

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

proc hasHeader*(db: MptAsmRef, bn = BlockNumber(0)): BoolResult =
  let data = db.get9(cHeader, bn).valueOr:
    return err(error)
  ok(0 < data.len)

proc getHeader*(db: MptAsmRef, bn: BlockNumber): HeaderResult =
  let data = db.get9(cHeader, bn).valueOr:
    return err(error)
  data.decodeHeader()

proc lastHeader*(db: MptAsmRef): HeaderResult =
  let data = db.get9(cHeader, 0u64).valueOr:
    return err(error)
  if data.len != 8:
    return err("")
  db.getHeader uint64.fromBytesBE data

proc putHeader*(db: MptAsmRef, header: Header): PutResult =
  db.put9(cHeader, header.number, header.encodeHeader()).isOkOr:
    return err(error)
  db.put9(cHeader, 0u64, uint64(header.number).toBytesBE()).isOkOr:
    return err(error)
  ok()

proc putHeader*(db: MptAsmRef, headers: openArray[Header]): PutResult =
  for h in headers:
    db.put9(cHeader, h.number, h.encodeHeader()).isOkOr:
      return err(error)
  db.put9(cHeader, 0u64, uint64(headers[^1].number).toBytesBE()).isOkOr:
    return err(error)
  ok()

proc delHeader*(db: MptAsmRef, bn: BlockNumber): DelResult =
  db.del9(cHeader, bn)

proc clearHeader*(db: MptAsmRef): DelResult =
  db.adb.rClear(cHeader)

iterator walkHeader*(db: MptAsmRef): WalkHeader =
  for (key,data) in db.adb.colWalk9 key9(cHeader, 1u64):
    let header = data.decodeHeader().valueOr:
      var oops: WalkHeader
      oops.error = error
      yield oops
      continue
    yield (header,"")

# ========================

proc getStateData*(
    db: MptAsmRef;
    root: StateRoot;
      ): Result[CachedStateData,string] =
  let data = db.get33(cStateData, root).valueOr:
    return err(error)
  data.decodeStateData()

proc putStateData*(
    db: MptAsmRef;
    root: StateRoot;
    data: CachedStateData;
      ): PutResult =
  db.put33(cStateData, root, encodeStateData(
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
  db.put33(cStateData, root,
           encodeStateData(hash, number, touch, tag, coverage))

proc putStateData*(
    db: MptAsmRef;
    state: WalkStateData;
      ): PutResult =
  db.put33(cStateData, state.root,
    encodeStateData(
      state.hash, state.number, state.touch, state.tag, state.coverage))

proc delStateData*(db: MptAsmRef; root: StateRoot): DelResult =
  db.del33(cStateData, root)

iterator walkStateData*(db: MptAsmRef): WalkStateData =
  for (key,value) in db.adb.colWalk33 cStateData.key33():
    let w = value.decodeStateData().valueOr:
        var oops: WalkStateData
        oops.root = StateRoot(key)
        oops.error = error
        yield oops
        continue
    yield (StateRoot(key), w.hash, w.number, w.touch, w.tag, w.coverage, "")

# -------------

proc getAccount*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): Result[DecodedAccount,string] =
  let data = db.get65(cAccount, root, start).valueOr:
    return err(error)
  data.decodeAccount()

proc putAccount*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
    accounts: seq[SnapAccount];
    proof: seq[ProofNode];
    peerID: Hash;
      ): PutResult =
  db.put65(
    cAccount, root, start, encodeAccount(limit, accounts, proof, peerID))

proc delAccount*(db: MptAsmRef; root: StateRoot; start: ItemKey): DelResult =
  db.del65(cAccount, root, start)

proc clearAccount*(db: MptAsmRef): DelResult =
  db.adb.rClear(cAccount)

iterator walkAccount*(db: MptAsmRef): WalkAccount =
  for (key1,key2,value) in db.adb.colWalk65 cAccount.key65():
    let
      root = StateRoot(key1)
      start = key2.to(ItemKey)
      w = value.decodeAccount().valueOr:
        var oops: WalkAccount
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w.limit, w.accounts, w.proof, w.peerID, "")

iterator walkAccount*(db: MptAsmRef, root: StateRoot): WalkAccount =
  ## Variant of `walkAccount()` for fixed `root`
  for (key1,key2,value) in db.adb.colWalk65 cAccount.key65(root):
    if StateRoot(key1) != root:
      break
    let
      start = key2.to(ItemKey)
      w = value.decodeAccount().valueOr:
        var oops: WalkAccount
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
  let data = db.get97(cStoSlot, root, account, start).valueOr:
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
    cStoSlot, root, acc, start, encodeStoSlot(limit, slot, proof, peerID))

proc putStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    slot: seq[StorageItem];
    peerID: Hash;
      ): PutResult =
  db.put97(
    cStoSlot, root, acc, low(ItemKey),
    encodeStoSlot(high(ItemKey), slot, EmptyProof, peerID))

proc delStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
      ): DelResult =
  db.del97(cStoSlot, root, acc, start)

proc clearStoSlot*(db: MptAsmRef): DelResult =
  db.adb.rClear(cStoSlot)

iterator walkStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
      ): WalkStoSlot =
  ## Variant of `walkStoSlot()` for fixed `root`
  let aHash = acc.to(Hash32)
  for (k1,k2,k3,val) in db.adb.colWalk97 cStoSlot.key97(root,aHash):
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
  let data = db.get65(cByteCode, root, start).valueOr:
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
  db.put65(cByteCode, root, start, encodeByteCode(limit, codes, peerID))

proc delByteCode*(db: MptAsmRef; root: StateRoot; start: ItemKey): DelResult =
  db.del65(cByteCode, root, start)

proc clearByteCode*(db: MptAsmRef): DelResult =
  db.adb.rClear(cByteCode)

iterator walkByteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): WalkByteCode =
  ## Variant of `walkAccount()` for fixed `root` and `start` account
  let startHash = start.to(Hash32)
  for (key1,key2,value) in db.adb.colWalk65 cByteCode.key65(root,startHash):
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

# ========================

proc hasAccKvt*(db: MptAsmRef; key: openArray[byte]): BoolResult =
  var data = db.getAtMost33(cAccKvt, key).valueOr:
    return err(error)
  ok(0 < data.len)

proc getAccKvt*(db: MptAsmRef; key: openArray[byte]): BlobResult =
  var data = db.getAtMost33(cAccKvt, key).valueOr:
    return err(error)
  ok(move data)

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

# -------------

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
