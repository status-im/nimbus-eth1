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
## counters, and drop handling for non-trivial types (keys and values must be
## `supportsCopyMem`, so there is nothing to drop, and the original's
## `ALIVE_BIT` is only needed when there is).
##
## Reads also diverge from the original, which takes the bucket with a
## compare-exchange. Here a read is a seqlock: two plain tag samples around the
## entry, with no atomic read-modify-write and no write to the bucket line.

{.push raises: [].}

import std/[atomics, typetraits]

const
  LockedBit = 1'u
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

proc tryLock[K, V](b: ptr Bucket[K, V], prev: var uint): bool {.inline.} =
  ## Take the bucket for writing, whatever it currently holds. Never spins: a
  ## bucket already held by another writer is left alone.
  let state = b.tag.load(moRelaxed)
  if (state and LockedBit) != 0:
    return false
  prev = state
  var cmp = state
  b.tag.compareExchange(cmp, state or LockedBit, moAcquire, moRelaxed)

proc getBySlot*[K, V](
    c: var FixedCache[K, V], slot: Slot, key: auto, val: var V): bool {.inline.} =
  ## Returns true and fills `val` if `key` is resident.
  ##
  ## Seqlock read: no atomic read-modify-write, so a lookup never writes to the
  ## bucket line and never blocks a writer. The tag is sampled before and after
  ## reading the entry; if a writer touched the bucket in between, or holds it
  ## now, the read is discarded and reported as a miss. Callers recompute on a
  ## miss, so losing the race is always safe.
  ##
  ## The low bits of the tag word (below the index bits, which are always zero
  ## in a tag) carry a version counter incremented on every insert. Without it
  ## a writer could replace an entry and restore the same tag between the two
  ## samples, and the reader would return a torn key/value pair as a hit.
  mixin `==`
  let
    b = addr c.entries[slot.idx]
    versionMask = c.indexMask()
    t1 = b.tag.load(moAcquire)

  if (t1 and LockedBit) != 0 or (t1 and not versionMask) != slot.tag:
    return false

  if not (b.key == key):
    return false
  val = b.val

  # Order the entry reads before the second sample. An acquire load suffices
  # and avoids naming the C11 fence enum, which differs from `MemoryOrder`.
  b.tag.load(moAcquire) == t1

proc putBySlot*[K, V](c: var FixedCache[K, V], slot: Slot, key: K, val: V) {.inline.} =
  ## Insert, evicting whatever occupies the bucket. A bucket currently held by
  ## another writer is left alone and the insert is dropped.
  let
    b = addr c.entries[slot.idx]
    versionMask = c.indexMask()
  var prev: uint
  if not b.tryLock(prev):
    return
  b.key = key
  b.val = val
  # Publish with the version bumped, so any reader that sampled the old tag
  # before this write sees a different value on its second sample.
  let version = ((prev and versionMask) + (LockedBit shl 1)) and
    versionMask and not LockedBit
  b.tag.store((slot.tag or version), moRelease)

proc get*[K, V](c: var FixedCache[K, V], key: K, val: var V): bool =
  c.getBySlot(c.locate(key), key, val)

proc put*[K, V](c: var FixedCache[K, V], key: K, val: V) =
  c.putBySlot(c.locate(key), key, val)

{.pop.}
