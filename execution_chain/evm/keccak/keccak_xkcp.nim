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
  ../../concurrency/fixed_cache

export eth_hashes.Hash32

const
  srcPath = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
  rapidhashHeader = srcPath & "/rapidhash.h"

{.compile: srcPath & "/keccak_xkcp.c".}

func rapidhashMicro(key: pointer, len: csize_t): uint64 {.
  importc: "rapidhashMicro", header: rapidhashHeader.}

func keccak256_xkcp(inp: ptr byte, inLen: csize_t, output: ptr byte) {.cdecl,
  importc: "keccak256_xkcp".}

func keccak256XkcpUncached*(data: openArray[byte]): Hash32 =
  let inp: ptr byte =
    if data.len == 0: nil
    else: unsafeAddr data[0]
  keccak256_xkcp(inp, csize_t(data.len), addr result.data[0])

const
  MaxCachedInputLen* = 87
  DefaultKeccakCacheCapacity* = 1 shl 17

type
  KeccakCacheKey = object
    len: uint8
    data: array[MaxCachedInputLen, byte]

func `==`(a, b: KeccakCacheKey): bool =
  a.len == b.len and
    equalMem(unsafeAddr a.data[0], unsafeAddr b.data[0], int(a.len))

func hash(k: KeccakCacheKey): Hash =
  cast[Hash](rapidhashMicro(unsafeAddr k.data[0], csize_t(k.len)))

static:
  doAssert sizeof(KeccakCacheKey) + sizeof(Hash32) + sizeof(uint) <= 128

var keccakCache: FixedCache[KeccakCacheKey, Hash32]

keccakCache.init(DefaultKeccakCacheCapacity)

proc keccak256Xkcp*(data: openArray[byte]): Hash32 =
  if data.len == 0:
    return emptyKeccak256
  if data.len > MaxCachedInputLen:
    return keccak256XkcpUncached(data)

  var key: KeccakCacheKey
  key.len = uint8(data.len)
  copyMem(addr key.data[0], unsafeAddr data[0], data.len)

  {.cast(gcsafe).}:
    let slot = keccakCache.locate(key)
    if keccakCache.getBySlot(slot, key, result):
      return result
    result = keccak256XkcpUncached(data)
    keccakCache.putBySlot(slot, key, result)

{.pop.}
