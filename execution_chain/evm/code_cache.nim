# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  eth/common/hashes,
  ../concurrency/lru,
  ./code_bytes

export code_bytes

const codeLruSize* = 16*1024
  # An LRU cache of 16K items gives roughly 90% hit rate anecdotally on a
  # small range of test blocks - this number could be studied in more detail
  # Since EIP-7954, the code of a contract can be up to
  # `EIP7954_MAX_CODE_SIZE` = 64kb (24kb before, per EIP-170), which would
  # cause a worst case of 1GB memory usage though in reality code sizes are
  # much smaller - it would make sense to study these numbers in greater
  # detail.

# Process-wide code cache shared by every ledger and thread. The cache holds
# one reference to each blob - lookups hand the caller a reference of its own,
# taken while the shard lock is held so that eviction cannot free the blob in
# between.
var codeCache: ConcurrentLruCache[Hash32, CodeBlob]
codeCache.init(codeLruSize, threadSafe = true)

proc acquireCached*(codeHash: Hash32): CodeBlob =
  ## Looks up `codeHash`, returning a blob reference owned by the caller or
  ## nil when the code is not cached
  codeCache.withGet(codeHash, blob):
    result = blob
    result.incRef()

proc peekCached*(codeHash: Hash32): CodeBlob =
  ## Like `acquireCached` but leaves the cache recency unchanged
  codeCache.withPeek(codeHash, blob):
    result = blob
    result.incRef()

proc insertCached*(codeHash: Hash32, blob: CodeBlob) =
  ## Admits `blob` into the cache, which takes a reference of its own
  blob.incRef()
  let evicted = codeCache.putWithEvicted(codeHash, blob)
  if evicted.isSome():
    evicted[].release()

proc codeCacheLen*(): int =
  codeCache.len()

proc resetCodeCache*(capacity = codeLruSize, threadSafe = true) =
  ## Drops every cached blob and reinitialises the cache - only for use while
  ## no other thread is touching it
  for blob in codeCache.mvalues():
    blob.release()
  codeCache.dispose()
  reset(codeCache)
  if threadSafe:
    codeCache.init(capacity)
  else:
    codeCache.init(capacity, shardBits = 0, threadSafe = false)
