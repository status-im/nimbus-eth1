# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  std/[hashes, os, strutils],
  eth/common/hashes as eth_hashes,
  ../../concurrency/fixed_cache,
  ./keccak_xkcp

export eth_hashes.Hash32

const
  srcPath = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
  rapidhashHeader = srcPath & "/rapidhash.h"

func rapidhashMicro(key: pointer, len: csize_t): uint64 {.
  importc: "rapidhashMicro", header: rapidhashHeader.}

func keccak256XkcpUncached*(data: openArray[byte]): Hash32 =
  keccak256XkcpNim(data, result.data)

const
  MaxCachedInputLen* = 87
  DefaultKeccakCacheCapacity* = 1 shl 14

type
  KeccakCacheKey = object
    len: uint8
    data: array[MaxCachedInputLen, byte]

# A lookup is done against the caller's bytes directly - hashing and comparing
# a borrowed view rather than building a KeccakCacheKey first. Only an insert
# needs the owned key. `hash(KeccakCacheKey)` is defined in terms of the
# openArray one so the two can never disagree: if they did, every lookup would
# probe a different bucket than the matching insert wrote, and the cache would
# silently never hit while still returning correct digests.
func hash(data: openArray[byte]): Hash =
  cast[Hash](rapidhashMicro(unsafeAddr data[0], csize_t(data.len)))

func hash(k: KeccakCacheKey): Hash =
  hash(k.data.toOpenArray(0, int(k.len) - 1))

func `==`(k: KeccakCacheKey, data: openArray[byte]): bool =
  int(k.len) == data.len and
    equalMem(unsafeAddr k.data[0], unsafeAddr data[0], data.len)

func `==`(a, b: KeccakCacheKey): bool =
  a == b.data.toOpenArray(0, int(b.len) - 1)

static:
  doAssert sizeof(KeccakCacheKey) + sizeof(Hash32) + sizeof(uint) <= 128

var keccakCache: FixedCache[KeccakCacheKey, Hash32]

keccakCache.init(DefaultKeccakCacheCapacity)

proc keccak256Xkcp*(data: openArray[byte]): Hash32 {.inline.} =
  if data.len == 0:
    return emptyKeccak256
  if data.len > MaxCachedInputLen:
    return keccak256XkcpUncached(data)

  {.cast(gcsafe).}:
    let slot = keccakCache.locate(data)
    if keccakCache.getBySlot(slot, data, result):
      return result

    result = keccak256XkcpUncached(data)

    var key: KeccakCacheKey
    key.len = uint8(data.len)
    copyMem(addr key.data[0], unsafeAddr data[0], data.len)
    keccakCache.putBySlot(slot, key, result)

{.pop.}
