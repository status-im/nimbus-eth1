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
  ../../concurrency/lru

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

func hash(k: KeccakCacheKey): Hash =
  cast[Hash](rapidhashMicro(unsafeAddr k.data[0], csize_t(k.len)))

var keccakCache: ConcurrentLruCache[KeccakCacheKey, Hash32]

keccakCache.init(DefaultKeccakCacheCapacity, shardBits = 0, threadSafe = false)

proc keccakCacheLen*(): int =
  {.cast(gcsafe).}:
    keccakCache.len()

proc keccak256Xkcp*(data: openArray[byte]): Hash32 =
  if data.len == 0:
    return emptyKeccak256
  if data.len > MaxCachedInputLen:
    return keccak256XkcpUncached(data)

  var key: KeccakCacheKey
  key.len = uint8(data.len)
  copyMem(addr key.data[0], unsafeAddr data[0], data.len)

  {.cast(gcsafe).}:
    let kh = keccakCache.toKeyHash(key)
    keccakCache.withGetByHash(kh, key, cached):
      return cached
    do:
      result = keccak256XkcpUncached(data)
      keccakCache.putByHash(kh, key, result)

{.pop.}
