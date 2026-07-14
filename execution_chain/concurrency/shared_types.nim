# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

# This module contains "shared" variants of standard library container types
# which, unlike their standard library counterparts, do not use any GC memory
# and instead store their data in memory allocated on the shared heap. This is
# needed to support multi-threaded use cases when using refc. None of these
# types are thread-safe.

{.push raises: [], gcsafe.}

import std/[hashes, math, typetraits], results
from system/ansi_c import c_realloc, c_free

export hashes, results

# SharedSeq is needed in order to pass sequences (e.g. seq[byte]) between threads
# safely when using refc. SharedBytes and SharedString are the byte and char
# specialisations used to pass bytes and strings across thread boundaries.

type
  SharedSeq*[E] = object
    data: ptr UncheckedArray[E]
    count: int
    cap: int

const seqInitialCapacity = 16

proc reallocTo[E](s: var SharedSeq[E], newCap: int) =
  s.data = cast[ptr UncheckedArray[E]](c_realloc(s.data, csize_t(newCap * sizeof(E))))
  s.cap = newCap

proc init*[E](T: type SharedSeq[E], len: int, zeroed = true): SharedSeq[E] =
  static:
    doAssert supportsCopyMem(E), "E must be a non-GC type"

  if len <= 0:
    return T()

  result.reallocTo(len)
  result.count = len
  if zeroed:
    zeroMem(result.data, len * sizeof(E))

proc init*[E](T: type SharedSeq[E], values: openArray[E]): SharedSeq[E] =
  var s = T.init(values.len(), zeroed = false)
  if values.len() > 0:
    copyMem(s.data, unsafeAddr values[0], values.len() * sizeof(E))
  s

proc dispose*[E](s: var SharedSeq[E]) =
  if not s.data.isNil():
    c_free(s.data)
    s.data = nil
  s.count = 0
  s.cap = 0

proc `=copy`*[E](
    dest: var SharedSeq[E], src: SharedSeq[E]
) {.error: "Copying SharedSeq is forbidden".} =
  discard

template toOpenArray[E](s: SharedSeq[E]): openArray[E] =
  s.data.toOpenArray(0, s.count - 1)

func toSeq[E](s: SharedSeq[E]): seq[E] =
  if s.count == 0:
    return default(seq[E])

  let res = newSeq[E](s.count)
  copyMem(addr res[0], s.data, s.count * sizeof(E))
  res

template data*[E](s: SharedSeq[E], asOpenArray: static bool = false): auto =
  when asOpenArray:
    s.toOpenArray()
  else:
    s.toSeq()

proc `[]`*[E](s: SharedSeq[E], i: int): lent E =
  s.data[i]

proc `[]`*[E](s: var SharedSeq[E], i: int): var E =
  s.data[i]

template len*[E](s: SharedSeq[E]): int =
  s.count

proc grow[E](s: var SharedSeq[E], minCap: int) =
  s.reallocTo(nextPowerOfTwo(max(minCap, seqInitialCapacity)))

proc setLen*[E](s: var SharedSeq[E], newLen: int, zeroed = true, exact = false) =
  if newLen > s.cap:
    if exact:
      s.reallocTo(newLen)
    else:
      s.grow(newLen)
  if zeroed and newLen > s.count:
    zeroMem(addr s.data[s.count], (newLen - s.count) * sizeof(E))
  s.count = newLen

proc add*[E](s: var SharedSeq[E], value: sink E) =
  if s.count == s.cap:
    s.grow(s.count + 1)
  copyMem(addr s.data[s.count], addr value, sizeof(E))
  inc s.count

iterator items*[E](s: SharedSeq[E]): lent E =
  for i in 0 ..< s.count:
    yield s.data[i]

iterator mitems*[E](s: var SharedSeq[E]): var E =
  for i in 0 ..< s.count:
    yield s.data[i]

type
  SharedBytes* = SharedSeq[byte]
  SharedString* = SharedSeq[char]

func toString*(s: SharedString): string =
  if s.count == 0:
    return default(string)

  let res = newString(s.count)
  copyMem(addr res[0], s.data, s.count)
  res

# SharedTable is a hash table similar to the standard library `Table`. Much of
# the robin-hood open addressing logic is adapted from the LruCache type in the
# concurrency/lru.nim file, simplified for a plain table by storing the key and
# value directly in each bucket and dropping the LRU linked list.
#
# Values are only ever moved (never copied) internally so the table can hold
# move-only, non-GC value types such as SharedBytes or even a nested SharedTable.
# As a consequence the table does not own the lifetime of its values: when the
# value type owns manually allocated memory (e.g. SharedBytes), the caller is
# responsible for disposing each value (via the `mvalues` iterator) before
# disposing the table.

type
  SharedTableEntry[K, V] = tuple[subhash: uint32, used: bool, key: K, value: V]

  SharedTable*[K, V] = object
    entries: ptr UncheckedArray[SharedTableEntry[K, V]]
    allocated: int
    used: int

const
  fillRatio = 2 / 3
  initialCapacity = 64

template toSubhash(h: Hash): uint32 =
  # Hashes will be masked by an uint32 value so we might as well reduce the
  # incoming hash value and save some memory - this might cost a few key
  # comparisons on collisions but the effect should be tiny
  when sizeof(h) == sizeof(uint32):
    uint32(h)
  else:
    static:
      assert sizeof(h) == sizeof(uint64)
    let hh = h
    uint32(hh) + uint32(uint64(hh) shr 32)

template subhash(value: auto): uint32 =
  mixin hash
  hash(value).toSubhash()

template psl(mask, bucket, subhash: uint32): uint32 =
  # distance from expected location aka probe sequence length - the power-of-two
  # mask and uint32 wrap-around ensures that even on underflow, the result is
  # well defined
  (bucket - subhash) and mask

func findEntry[K, V](s: SharedTable[K, V], sh: uint32, key: K): Opt[uint32] =
  ## Return the index of the slot holding `key`, if present.
  mixin `==`

  if s.allocated == 0:
    return Opt.none(uint32)

  let mask = uint32(s.allocated - 1)
  var
    i = sh and mask
    dist = 0'u32

  while true:
    let e = addr s.entries[i]
    if not e[].used or dist > psl(mask, i, e[].subhash):
      # An empty slot or an entry closer to its ideal slot than we are means the
      # key cannot be present further along the probe sequence.
      return Opt.none(uint32)

    if e[].subhash == sh and e[].key == key:
      return Opt.some(i)

    i = (i + 1) and mask
    dist += 1

proc placeEntry[K, V](
    s: var SharedTable[K, V], entry: sink SharedTableEntry[K, V], bucket, dist: uint32
) =
  ## Robin-hood placement: store `entry` (a key not already present), beginning
  ## the probe at `bucket` with probe distance `dist` and displacing any richer
  ## entry forward until an empty slot is reached. The caller must ensure a free
  ## slot exists (i.e. the fill ratio is respected).
  let mask = uint32(s.allocated - 1)
  var
    cur = move(entry)
    i = bucket
    d = dist

  while true:
    let e = addr s.entries[i]
    if not e[].used:
      e[] = move(cur)
      return

    let bdist = psl(mask, i, e[].subhash)
    if d > bdist:
      swap(e[], cur)
      d = bdist

    i = (i + 1) and mask
    d += 1

proc rawInsert[K, V](s: var SharedTable[K, V], sh: uint32, key: K, value: sink V) =
  ## Insert a key/value pair known not to be present.
  s.placeEntry((sh, true, key, value), sh and uint32(s.allocated - 1), 0)

proc grow[K, V](s: var SharedTable[K, V], newAllocated: int) =
  let
    old = s.entries
    oldAllocated = s.allocated

  # createShared zero-initializes the memory so every slot starts out unused.
  s.entries = cast[ptr UncheckedArray[SharedTableEntry[K, V]]](createShared(
    SharedTableEntry[K, V], newAllocated
  ))
  s.allocated = newAllocated

  for i in 0 ..< oldAllocated:
    if old[i].used:
      s.rawInsert(old[i].subhash, old[i].key, move(old[i].value))

  if oldAllocated > 0:
    deallocShared(old)

proc init*[K, V](T: type SharedTable[K, V], initialSize: int = 0): T =
  ## Create an empty table. If `initialSize` > 0, eagerly allocate enough slots
  ## to hold that many entries without growing.
  static:
    doAssert supportsCopyMem(K), "K must be a non-GC type"
    # V is intentionally not required to be `supportsCopyMem` so that move-only,
    # non-GC value types (e.g. SharedBytes or a nested SharedTable) are allowed.
    # V must still not contain any GC managed memory.

  if initialSize > 0:
    let allocated =
      max(initialCapacity, nextPowerOfTwo(int(ceil(initialSize.float / fillRatio))))
    result.entries = cast[ptr UncheckedArray[SharedTableEntry[K, V]]](createShared(
      SharedTableEntry[K, V], allocated
    ))
    result.allocated = allocated

proc dispose*[K, V](s: var SharedTable[K, V]) =
  ## Free the shared memory held by the table. Safe to call more than once.
  if s.allocated > 0:
    deallocShared(s.entries)
    s.entries = nil
    s.allocated = 0
    s.used = 0

proc `=copy`*[K, V](
    dest: var SharedTable[K, V], src: SharedTable[K, V]
) {.error: "Copying SharedTable is forbidden".} =
  discard

template len*[K, V](s: SharedTable[K, V]): int =
  ## Number of key/value pairs in the table.
  s.used

func contains*[K, V](s: SharedTable[K, V], key: K): bool =
  ## Return true iff `key` is present in the table.
  s.findEntry(subhash(key), key).isSome()

func get*[K, V](s: SharedTable[K, V], key: K): Opt[V] =
  ## Retrieve the value associated with `key`, if present.
  ##
  ## The value is copied out, so this requires a copyable V and will not compile
  ## for move-only value types (e.g. SharedBytes or a nested SharedTable); use
  ## `withValue` to borrow such values in place instead.
  let i = ?s.findEntry(subhash(key), key)
  Opt.some(s.entries[i].value)

template `[]`*[K, V](s: SharedTable[K, V], key: K): Opt[V] =
  s.get(key)

func getOrDefault*[K, V](s: SharedTable[K, V], key: K): V =
  ## Retrieve the value associated with `key`, or `default(V)` if `key` is
  ## absent.
  ##
  ## The value is copied out, so this requires a copyable V and will not compile
  ## for move-only value types (e.g. SharedBytes or a nested SharedTable); use
  ## `withValue` to borrow such values in place instead.
  let idx = s.findEntry(subhash(key), key)
  if idx.isSome():
    s.entries[idx[]].value
  else:
    default(V)

func getOrDefault*[K, V](s: SharedTable[K, V], key: K, default: V): V =
  ## Retrieve the value associated with `key`, or `default` if `key` is absent.
  ##
  ## The value is copied out, so this requires a copyable V and will not compile
  ## for move-only value types (e.g. SharedBytes or a nested SharedTable); use
  ## `withValue` to borrow such values in place instead.
  let idx = s.findEntry(subhash(key), key)
  if idx.isSome():
    s.entries[idx[]].value
  else:
    default

proc put*[K, V](s: var SharedTable[K, V], key: K, value: sink V) =
  ## Insert or update `key` with `value`, growing the table if needed.
  ##
  ## When `key` is already present its previous value is overwritten in place.
  ## If V owns manually allocated memory (e.g. SharedBytes or a nested
  ## SharedTable), the overwritten value is abandoned and leaked, so dispose the
  ## existing value first (e.g. via `withValue`) before updating an owning value.
  let sh = subhash(key)

  if s.allocated == 0:
    s.grow(initialCapacity)

  # Probe as a lookup would: the robin-hood invariant makes the slot where a
  # failed lookup stops the same slot where a new key must be inserted.
  let mask = uint32(s.allocated - 1)
  var
    i = sh and mask
    dist = 0'u32

  while true:
    let e = addr s.entries[i]
    if not e[].used or dist > psl(mask, i, e[].subhash):
      # Empty slot or a richer entry: `key` is absent and `i`/`dist` mark its
      # insertion point. Growth for the insert is deferred until after this
      # probe so that an in-place update never triggers a needless resize.
      break

    if e[].subhash == sh and e[].key == key:
      # Key already present: update in place. No new slot is consumed, so an
      # update never grows the table.
      e[].value = move(value)
      return

    i = (i + 1) and mask
    dist += 1

  # `key` is absent and must be inserted. Grow only now that a new entry will
  # actually be added; growth rehashes every entry and invalidates the probe
  # above, so in that case re-probe from the ideal bucket via `rawInsert`.
  if (s.used + 1) * 3 > s.allocated * 2: # used + 1 > fillRatio * allocated
    s.grow(s.allocated * 2)
    s.rawInsert(sh, key, value)
  else:
    s.placeEntry((sh, true, key, value), i, dist)
  s.used += 1

template `[]=`*(s: var SharedTable, key, value: untyped) =
  s.put(key, value)

proc removeEntry[K, V](s: var SharedTable[K, V], idx: uint32) =
  ## Close the hole left at `idx` with backward-shift deletion: pull following
  ## entries back until an empty slot or an entry already in its ideal slot is
  ## reached, then decrement the count. The value previously stored at `idx` is
  ## abandoned; callers that need to reclaim it must move it out beforehand.
  let mask = uint32(s.allocated - 1)
  var i = idx

  while true:
    let
      next = (i + 1) and mask
      e = addr s.entries[next]

    if not e[].used or psl(mask, next, e[].subhash) == 0:
      s.entries[i].used = false
      break

    # Move (never copy) so the table works with move-only value types such as
    # SharedBytes or a nested SharedTable. `move` leaves the source slot in its
    # default (unused) state, which is exactly the hole we shift into next.
    s.entries[i] = move(e[])
    i = next

  s.used -= 1

proc del*[K, V](s: var SharedTable[K, V], key: K): bool {.discardable.} =
  ## Remove `key` from the table, returning true if it was present. The removed
  ## value is discarded. If V owns manually allocated memory (e.g. SharedBytes
  ## or a nested SharedTable), use `pop` instead and dispose the returned value,
  ## otherwise that memory is leaked.
  let idx = s.findEntry(subhash(key), key).valueOr:
    return false

  s.removeEntry(idx)
  true

proc pop*[K, V](s: var SharedTable[K, V], key: K): Opt[V] =
  ## Remove `key` from the table and return its value, transferring ownership to
  ## the caller. Returns none if the key was absent. Prefer this over `del` when
  ## V owns memory so the caller can dispose the returned value.
  let idx = s.findEntry(subhash(key), key).valueOr:
    return Opt.none(V)

  # Move the value out before the backward-shift overwrites the slot.
  result = Opt.some(move(s.entries[idx].value))
  s.removeEntry(idx)

proc clear*[K, V](s: var SharedTable[K, V]) =
  ## Remove all entries, keeping the allocated memory for reuse.
  ##
  ## The stored values are discarded without being disposed. If V owns manually
  ## allocated memory (e.g. SharedBytes or a nested SharedTable), dispose each
  ## value first (via the `mvalues` iterator), otherwise that memory is leaked.
  if s.allocated > 0:
    zeroMem(s.entries, s.allocated * sizeof(SharedTableEntry[K, V]))
  s.used = 0

template withValue*[K, V](s: var SharedTable[K, V], key: K, val, body: untyped) =
  ## If `key` is present, run `body` with `val` injected as a `ptr V` pointing
  ## at the stored value. Does nothing if `key` is missing.
  ##
  ## `val` points into the table's storage and is invalidated by any operation
  ## that reallocates or rearranges entries (`put` that grows the table, `del`,
  ## `pop`, `clear`, `dispose`); do not retain it across such calls.
  let idx = s.findEntry(subhash(key), key)
  if idx.isSome():
    let val {.inject.} = addr s.entries[idx[]].value
    body

template withValue*[K, V](
    s: var SharedTable[K, V], key: K, val, body1, body2: untyped
) =
  ## Like the two-argument `withValue`, but additionally runs `body2` (typically
  ## written as a trailing `do:` block) when `key` is missing. `body1` runs with
  ## `val` injected as a `ptr V` pointing at the stored value, subject to the
  ## same invalidation caveats; `body2` runs with nothing injected.
  let idx = s.findEntry(subhash(key), key)
  if idx.isSome():
    let val {.inject.} = addr s.entries[idx[]].value
    body1
  else:
    body2

iterator keys*[K, V](s: SharedTable[K, V]): lent K =
  ## Iterate over the keys in the table in an unspecified order.
  if s.allocated > 0:
    for i in 0 ..< s.allocated:
      if s.entries[i].used:
        yield s.entries[i].key

iterator values*[K, V](s: SharedTable[K, V]): lent V =
  ## Iterate over the values in the table in an unspecified order.
  if s.allocated > 0:
    for i in 0 ..< s.allocated:
      if s.entries[i].used:
        yield s.entries[i].value

iterator mvalues*[K, V](s: var SharedTable[K, V]): var V =
  ## Iterate over mutable references to the values in an unspecified order.
  if s.allocated > 0:
    for i in 0 ..< s.allocated:
      if s.entries[i].used:
        yield s.entries[i].value

iterator pairs*[K, V](s: SharedTable[K, V]): (lent K, lent V) =
  ## Iterate over the key/value pairs in the table in an unspecified order.
  if s.allocated > 0:
    for i in 0 ..< s.allocated:
      if s.entries[i].used:
        yield (s.entries[i].key, s.entries[i].value)

iterator mpairs*[K, V](s: var SharedTable[K, V]): (lent K, var V) =
  ## Iterate over keys with mutable references to their values, in an
  ## unspecified order.
  if s.allocated > 0:
    for i in 0 ..< s.allocated:
      if s.entries[i].used:
        yield (s.entries[i].key, s.entries[i].value)
