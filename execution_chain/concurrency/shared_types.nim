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

export hashes, results

# SharedBytes is needed in order to pass bytes (e.g. seq[byte]) between threads
# safely when using refc.

type
  SharedBytes* = object
    data: ptr UncheckedArray[byte]
    len: int

proc init*(T: type SharedBytes, bytes: openArray[byte]): T =
  if bytes.len() == 0:
    return T()

  let sb =
    T(data: cast[ptr UncheckedArray[byte]](allocShared(bytes.len())), len: bytes.len())
  copyMem(sb.data, unsafeAddr bytes[0], bytes.len())

  sb

proc dispose*(sb: var SharedBytes) =
  if not sb.data.isNil():
    deallocShared(sb.data)
    sb.data = nil
    sb.len = 0

proc `=copy`*(
    dest: var SharedBytes, src: SharedBytes
) {.error: "Copying SharedBytes is forbidden".} =
  # Only a single owner is supported for now.
  discard

template toOpenArray(sb: SharedBytes): openArray[byte] =
  sb.data.toOpenArray(0, sb.len - 1)

func toSeq(sb: SharedBytes): seq[byte] =
  if sb.len == 0:
    return default(seq[byte])

  let s = newSeq[byte](sb.len)
  copyMem(addr s[0], sb.data, sb.len)
  s

template data*(sb: SharedBytes, asOpenArray: static bool = false): auto =
  when asOpenArray:
    sb.toOpenArray()
  else:
    sb.toSeq()

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
  fillRatio = 0.8
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

proc rawInsert[K, V](s: var SharedTable[K, V], sh: uint32, key: K, value: sink V) =
  ## Insert a key/value pair known not to be present. The caller must ensure a
  ## free slot exists (i.e. the fill ratio is respected).
  let mask = uint32(s.allocated - 1)
  var
    cur: SharedTableEntry[K, V] = (sh, true, key, value)
    i = sh and mask
    dist = 0'u32

  while true:
    let e = addr s.entries[i]
    if not e[].used:
      e[] = move(cur)
      return

    let bdist = psl(mask, i, e[].subhash)
    if dist > bdist:
      # Robin-hood: steal the slot from the richer entry and keep displacing it
      # forward, evening out the probe sequence lengths.
      swap(e[], cur)
      dist = bdist

    i = (i + 1) and mask
    dist += 1

proc grow[K, V](s: var SharedTable[K, V], newAllocated: int) =
  let
    old = s.entries
    oldAllocated = s.allocated

  # createShared zero-initializes the memory so every slot starts out unused.
  s.entries = cast[ptr UncheckedArray[SharedTableEntry[K, V]]](
    createShared(SharedTableEntry[K, V], newAllocated)
  )
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
    result.entries = cast[ptr UncheckedArray[SharedTableEntry[K, V]]](
      createShared(SharedTableEntry[K, V], allocated)
    )
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

template contains*[K, V](s: SharedTable[K, V], key: K): bool =
  ## Return true iff `key` is present in the table.
  s.findEntry(subhash(key), key).isSome()

func get*[K, V](s: SharedTable[K, V], key: K): Opt[V] =
  ## Retrieve the value associated with `key`, if present.
  let i = ?s.findEntry(subhash(key), key)
  Opt.some(s.entries[i].value)

template `[]`*[K, V](s: SharedTable[K, V], key: K): Opt[V] =
  s.get(key)

proc put*[K, V](s: var SharedTable[K, V], key: K, value: sink V) =
  ## Insert or update `key` with `value`, growing the table if needed.
  let sh = subhash(key)

  let existing = s.findEntry(sh, key)
  if existing.isSome():
    s.entries[existing[]].value = value
    return

  if s.allocated == 0:
    s.grow(initialCapacity)
  elif (s.used + 1) * 5 > s.allocated * 4: # used + 1 > fillRatio * allocated
    s.grow(s.allocated * 2)

  s.rawInsert(sh, key, value)
  s.used += 1

template `[]=`*(s: var SharedTable, key, value: untyped) =
  s.put(key, value)

proc del*[K, V](s: var SharedTable[K, V], key: K): bool {.discardable.} =
  ## Remove `key` from the table, returning true if it was present.
  let idx = s.findEntry(subhash(key), key).valueOr:
    return false

  let mask = uint32(s.allocated - 1)
  var i = idx

  # Backward-shift deletion: pull following entries back to fill the hole until
  # we reach an empty slot or an entry already sitting in its ideal slot.
  while true:
    let
      next = (i + 1) and mask
      e = addr s.entries[next]

    if not e[].used or psl(mask, next, e[].subhash) == 0:
      s.entries[i].used = false
      break

    s.entries[i] = e[]
    i = next

  s.used -= 1
  true

proc clear*[K, V](s: var SharedTable[K, V]) =
  ## Remove all entries, keeping the allocated memory for reuse.
  if s.allocated > 0:
    zeroMem(s.entries, s.allocated * sizeof(SharedTableEntry[K, V]))
  s.used = 0

template withValue*[K, V](
    s: var SharedTable[K, V], key: K, val, body: untyped
) =
  ## If `key` is present, run `body` with `val` injected as a `ptr V` pointing
  ## at the stored value. Does nothing if `key` is missing.
  let idx = s.findEntry(subhash(key), key)
  if idx.isSome():
    let val {.inject.} = addr s.entries[idx[]].value
    body

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
