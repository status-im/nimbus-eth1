# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/typetraits,
  pkg/[eth/common, stew/endians2, rocksdb],
  ./[cache_const, cache_desc]

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "snap sync"

type
  KkvTriple* = tuple
    ## Internal helper structure
    key1: seq[byte]
    key2: seq[byte]
    value: seq[byte]

# ------------------------------------------------------------------------------
# Private iterator helpers
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

# ------------------------------------------------------------------------------
# Public generic iterators
# ------------------------------------------------------------------------------

iterator colWalkAtLeast1*(adb: RocksDbRef, pfx: openArray[byte]): KvPair =
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

iterator colWalkAtLeast33*(adb: RocksDbRef, pfx: openArray[byte]): KkvTriple =
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

iterator colWalk9*(
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

iterator colWalk33*(
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

iterator colWalk65*(
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

iterator colWalk97*(
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
# End
# ------------------------------------------------------------------------------
