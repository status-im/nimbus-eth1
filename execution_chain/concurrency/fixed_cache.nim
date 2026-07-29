# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## A minimalistic, lock-free, fixed-size cache.
##
## Port of the `fixed-cache` Rust crate (MIT, Daniel Popescu), which
## alloy-primitives uses for revm's keccak cache. Structure and protocol follow
## the original closely:
##
## * one-way set associative: a key maps to exactly one bucket, `hash and
##   indexMask`. There is no probing and no chaining.
## * collisions evict unconditionally - the newer entry replaces the older.
## * each bucket is its own 128-byte cache line, holding an atomic tag plus the
##   key/value pair, so buckets never falsely share.
## * the tag packs the hash bits *above* the index bits, leaving the low bits
##   for flags. `capacity` must therefore be a power of two with at least
##   `NeededBits` low zero bits, which `init` asserts.
## * synchronisation is a per-bucket lock that never spins: a single
##   compare-exchange, and on failure the operation is abandoned rather than
##   retried. A lookup that loses the race simply reports a miss, so callers
##   fall back to computing the value. Correctness never depends on winning.
##
## Deliberately not ported: the epoch/`clear` machinery, the optional statistics
## counters, and drop handling for non-trivial types. Keys and values here must be `supportsCopyMem`, so there
## is nothing to drop, which is also why `AliveBit` is never set (the original
## sets it only when `NEEDS_DROP`).

{.push raises: [].}

import std/[atomics, typetraits]

const
  LockedBit = 1'u
  AliveBit {.used.} = 2'u
  NeededBits = 2
  CacheLineSize = 128

type
  Bucket[K, V] = object
    tag {.align: CacheLineSize.}: Atomic[uint]
    key: K
    val: V

  FixedCache*[K, V] = object
    entries: ptr UncheckedArray[Bucket[K, V]]
    numEntries: int

  Slot* = object
    ## Result of hashing a key once, so a lookup and the insert that follows it
    ## share the work. Mirrors the original's `calc`.
    idx*: int
    tag*: uint

func capacity*[K, V](c: FixedCache[K, V]): int =
  c.numEntries

func indexMask[K, V](c: FixedCache[K, V]): uint =
  uint(c.numEntries) - 1

func tagMask[K, V](c: FixedCache[K, V]): uint =
  not c.indexMask()

proc init*[K, V](c: var FixedCache[K, V], entries: int) =
  ## `entries` must be a power of two and a multiple of `1 shl NeededBits`, so
  ## that the tag bits never overlap the flag bits.
  static:
    doAssert supportsCopyMem(K), "K must be a non-GC type"
    doAssert supportsCopyMem(V), "V must be a non-GC type"
  doAssert entries >= (1 shl NeededBits), "entries too small"
  doAssert (entries and (entries - 1)) == 0, "entries must be a power of two"

  c.numEntries = entries
  c.entries = cast[ptr UncheckedArray[Bucket[K, V]]](
    allocShared0(sizeof(Bucket[K, V]) * entries))

proc dispose*[K, V](c: var FixedCache[K, V]) =
  if c.entries != nil:
    deallocShared(c.entries)
    c.entries = nil
    c.numEntries = 0

func locate*[K, V](c: FixedCache[K, V], key: auto): Slot {.inline.} =
  ## Hash `key` once; the token is valid for `get` and `put` on the same key.
  mixin hash
  let h = cast[uint](hash(key))
  Slot(idx: int(h and c.indexMask()), tag: h and c.tagMask())

proc tryLock[K, V](b: ptr Bucket[K, V], expected: uint,
                   hasExpected: bool): bool {.inline.} =
  let state = b.tag.load(moRelaxed)
  if hasExpected:
    if state != expected:
      return false
  elif (state and LockedBit) != 0:
    return false

  var cmp = state
  b.tag.compareExchange(cmp, state or LockedBit, moAcquire, moRelaxed)

proc unlock[K, V](b: ptr Bucket[K, V], tag: uint) {.inline.} =
  b.tag.store(tag, moRelease)

proc getBySlot*[K, V](
    c: var FixedCache[K, V], slot: Slot, key: auto, val: var V): bool {.inline.} =
  ## Returns true and fills `val` if `key` is resident. A bucket held by
  ## another thread, or holding a different tag, reports a miss.
  mixin `==`
  let b = addr c.entries[slot.idx]
  if b.tryLock(slot.tag, true):
    if b.key == key:
      val = b.val
      b.unlock(slot.tag)
      return true
    b.unlock(slot.tag)
  false

proc putBySlot*[K, V](c: var FixedCache[K, V], slot: Slot, key: K, val: V) {.inline.} =
  ## Insert, evicting whatever occupies the bucket. A bucket currently locked
  ## by another thread is left alone and the insert is dropped.
  let b = addr c.entries[slot.idx]
  if not b.tryLock(0, false):
    return
  b.key = key
  b.val = val
  b.unlock(slot.tag)

proc get*[K, V](c: var FixedCache[K, V], key: K, val: var V): bool =
  c.getBySlot(c.locate(key), key, val)

proc put*[K, V](c: var FixedCache[K, V], key: K, val: V) =
  c.putBySlot(c.locate(key), key, val)

{.pop.}
