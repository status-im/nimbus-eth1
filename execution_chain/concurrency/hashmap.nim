# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## LockFreeHashMap is a thread-safe concurrent hash map designed for high
## throughput multi-threaded reads and writes. It uses open-addressing with
## linear probing on a single global table. All happy-path operations (`get`,
## `put`, `update`, `del`, `pop`, `contains`) are lock-free; no shared lock is
## ever acquired.
##
## Capacity is fixed at `init` time. The internal table is allocated on the
## shared heap via `createShared` and never reallocated, so no `ref` types and
## no GC are involved. If the table fills past its load-factor threshold,
## `put` returns `false` and the caller is expected to size the table
## appropriately at construction time.
##
## Concurrency protocol
## --------------------
## Each slot has an atomic control word that packs a state machine and a
## version counter. Writers transition the state via CAS and bump the version
## on every transition. Readers use a seqlock-style protocol: load the
## control word with acquire, read the key/value (which are plain non-atomic
## fields), reload the control word, and retry the slot if the version
## changed during the read. This protocol works for arbitrary value types
## (`K`/`V` are not restricted to word-sized).
##
## Slot state machine:
##   sEmpty -> sClaimed -> sValid -> sUpdating -> sValid -> sTombstone
##   sTombstone -> sClaimed (revive) -> sValid
##
## Insertion may reuse a tombstone slot when a new key probes past it. The
## "spin on sClaimed/sUpdating" rule ensures that two concurrent inserts of
## the same key cannot both succeed at different slots: a probe never
## advances past an in-progress claim, so the second inserter is forced to
## observe whatever the first inserter publishes.

{.push raises: [], gcsafe.}

import std/[atomics, hashes, math, typetraits], results

export hashes, results

const
  fillRatio = 0.8
    ## Target maximum load factor.
  minSlots = 2
    ## Smallest power-of-two slot count.

  STATE_BITS = 3'u32
  STATE_MASK = (1'u32 shl STATE_BITS) - 1'u32

type
  SlotState = enum
    sEmpty     = 0
    sClaimed   = 1
    sValid     = 2
    sUpdating  = 3
    sTombstone = 4

  Slot[K, V] = object
    control: Atomic[uint32]
      ## Bits 0-2: state. Bits 3-31: version counter (29 bits, monotonically
      ## incremented on every state transition). Initial value is 0
      ## (state=sEmpty, version=0); `createShared` zeroes the slot array so no
      ## explicit init is needed.
    subhash: uint32
      ## Cached short hash for fast probe filtering. Written by the writer
      ## while the slot is in sClaimed; readable any time the slot is sValid.
    key: K
    value: V

  LockFreeHashMap*[K, V] = object
    slots: ptr UncheckedArray[Slot[K, V]]
    slotsLen: int
      ## Always a power of two, fixed for the life of the map.
    mask: uint64
    capacityVal: int
      ## Maximum number of live entries the user requested. The slot array is
      ## sized to hold `capacityVal / fillRatio` rounded up to a power of two.
    used: Atomic[int]
      ## Approximate live-entry count. Updated with relaxed ordering; may lag
      ## under in-flight ops.

# ---------------------------------------------------------------- helpers ----

template controlState(c: uint32): SlotState =
  SlotState(c and STATE_MASK)

template encodeControl(s: SlotState, version: uint32): uint32 =
  (version shl STATE_BITS) or uint32(s)

template advanceControl(c: uint32, newState: SlotState): uint32 =
  ## Bump version by 1 and switch to `newState`.
  ((c shr STATE_BITS) + 1'u32) shl STATE_BITS or uint32(newState)

template toSubhash(h: Hash): uint32 =
  when sizeof(h) == sizeof(uint32):
    uint32(h)
  else:
    static:
      assert sizeof(h) == sizeof(uint64)
    let hh = h
    uint32(hh) + uint32(uint64(hh) shr 32)

template subhashOf(value: auto): uint32 =
  mixin hash
  toSubhash(hash(value))

template hashIndex(m: LockFreeHashMap, key: auto): uint64 =
  mixin hash
  uint64(hash(key)) and m.mask

# --------------------------------------------------------------- lifecycle ---

proc init*[K, V](T: type LockFreeHashMap[K, V], capacity: int): T =
  ## Create a map with capacity for at least `capacity` live entries.
  ## The internal table is sized to `capacity / fillRatio` rounded up to a
  ## power of two. The map cannot grow past this capacity; callers must size
  ## generously.
  let
    requested = max(1, capacity)
    target = max(minSlots, int(ceil(requested.float / fillRatio)))
    actualSlots = nextPowerOfTwo(target)
  result.slots = cast[ptr UncheckedArray[Slot[K, V]]](
    createShared(Slot[K, V], actualSlots))
  result.slotsLen = actualSlots
  result.mask = uint64(actualSlots - 1)
  result.capacityVal = capacity

proc dispose*[K, V](m: var LockFreeHashMap[K, V]) =
  ## Free the underlying slot array. The caller must ensure no other thread
  ## is operating on the map.
  if m.slots != nil:
    when not supportsCopyMem(K) or not supportsCopyMem(V):
      for i in 0 ..< m.slotsLen:
        let s = controlState(m.slots[i].control.load(moRelaxed))
        if s != sEmpty and s != sTombstone:
          when not supportsCopyMem(K):
            reset(m.slots[i].key)
          when not supportsCopyMem(V):
            reset(m.slots[i].value)
    deallocShared(m.slots)
    m.slots = nil
  m.slotsLen = 0
  m.mask = 0
  m.capacityVal = 0

# -------------------------------------------------------------- inspection ---

func capacity*(m: LockFreeHashMap): int =
  m.capacityVal

func slotsLen*(m: LockFreeHashMap): int =
  m.slotsLen

proc len*[K, V](m: var LockFreeHashMap[K, V]): int =
  ## Approximate count of live entries. Under concurrent mutation this lags
  ## by up to the number of in-flight operations; it is exact under quiesced
  ## conditions.
  m.used.load(moRelaxed)

# ------------------------------------------------------ low-level operations -

template spinUntilStable(slot: ptr Slot, c: var uint32) =
  ## While a writer is mid-transition on `slot`, reload `c`. The transition
  ## sClaimed/sUpdating -> sValid is unconditional (writers never abort), so
  ## this terminates as soon as the writer publishes.
  while (let s = controlState(c); s == sClaimed or s == sUpdating):
    c = slot.control.load(moAcquire)

proc tryClaim[K, V](
    slot: ptr Slot[K, V],
    expected: var uint32,
    desired: uint32
): bool =
  slot.control.compareExchange(expected, desired, moAcquireRelease, moAcquire)

# -------------------------------------------------------- read-only lookup ---

type
  LookupOutcome = enum
    loFound
    loEmpty   ## hit sEmpty: key not in map
    loSwept   ## probed all slots without finding key or empty
    loRetry   ## seqlock failure: caller should retry

proc lookup[K, V](
    m: var LockFreeHashMap[K, V],
    key: auto,
    sh: uint32,
    h: uint64,
    outValue: var V
): LookupOutcome =
  ## Read-only probe. On `loFound`, `outValue` holds the matched value.
  for probe in 0 ..< m.slotsLen:
    let idx = int((h + uint64(probe)) and m.mask)
    let slot = addr m.slots[idx]

    var c1 = slot.control.load(moAcquire)
    spinUntilStable(slot, c1)

    case controlState(c1)
    of sEmpty:
      return loEmpty
    of sTombstone:
      continue
    of sValid:
      if slot.subhash != sh:
        let c2 = slot.control.load(moAcquire)
        if c1 != c2:
          return loRetry
        continue
      let slotKey = slot.key
      let c3 = slot.control.load(moAcquire)
      if c1 != c3:
        return loRetry
      if not (slotKey == key):
        continue
      outValue = slot.value
      let c4 = slot.control.load(moAcquire)
      if c1 != c4:
        return loRetry
      return loFound
    of sClaimed, sUpdating:
      discard # spun above
  loSwept

proc get*[K, V](m: var LockFreeHashMap[K, V], key: auto): Opt[V] =
  if m.slotsLen == 0:
    return Opt.none(V)
  let
    sh = subhashOf(key)
    h = m.hashIndex(key)
  var v: V
  while true:
    case lookup(m, key, sh, h, v)
    of loFound:
      return Opt.some(v)
    of loEmpty, loSwept:
      return Opt.none(V)
    of loRetry:
      discard

proc contains*[K, V](m: var LockFreeHashMap[K, V], key: auto): bool =
  if m.slotsLen == 0:
    return false
  let
    sh = subhashOf(key)
    h = m.hashIndex(key)
  var v: V
  while true:
    case lookup(m, key, sh, h, v)
    of loFound:
      return true
    of loEmpty, loSwept:
      return false
    of loRetry:
      discard

# --------------------------------------------------- write-side probe sweep -

type
  ProbeResult = enum
    prMatch       ## found existing key at matchIdx; caller should update/delete
    prInsertHere  ## hit sEmpty or saw a tombstone earlier; caller may insert
    prFull        ## probed all slots, no match and no empty/tombstone
    prRetry       ## seqlock failure; caller should restart the probe

  ProbeState = object
    matchIdx: int
    matchC: uint32
    insertIdx: int
    insertC: uint32

proc probeForWrite[K, V](
    m: var LockFreeHashMap[K, V],
    key: auto,
    sh: uint32,
    h: uint64,
    state: var ProbeState
): ProbeResult =
  ## Linear probe that records both the first slot eligible for insertion
  ## (first tombstone, or the first sEmpty if no earlier tombstone) and any
  ## existing slot holding `key`. Tombstones are eligible insert targets, so
  ## this scans the full probe sequence past tombstones to confirm the key is
  ## not present further along.
  state.matchIdx = -1
  state.insertIdx = -1
  var sawEmpty = false
  for probe in 0 ..< m.slotsLen:
    let idx = int((h + uint64(probe)) and m.mask)
    let slot = addr m.slots[idx]
    var c = slot.control.load(moAcquire)
    spinUntilStable(slot, c)

    case controlState(c)
    of sEmpty:
      if state.insertIdx < 0:
        state.insertIdx = idx
        state.insertC = c
      sawEmpty = true
      break
    of sTombstone:
      if state.insertIdx < 0:
        state.insertIdx = idx
        state.insertC = c
    of sValid:
      if slot.subhash == sh:
        let slotKey = slot.key
        let c2 = slot.control.load(moAcquire)
        if c2 != c:
          return prRetry
        if slotKey == key:
          state.matchIdx = idx
          state.matchC = c
          return prMatch
    of sClaimed, sUpdating:
      discard # spun above

  if state.matchIdx >= 0:
    return prMatch
  if state.insertIdx >= 0:
    return prInsertHere
  if sawEmpty:
    # sEmpty was found but insertIdx was already a tombstone — covered above.
    return prInsertHere
  prFull

# ----------------------------------------------------------- public writes ---

proc put*[K, V](m: var LockFreeHashMap[K, V], key: K, value: V): bool =
  ## Insert `key`/`value` if absent, or overwrite the existing entry.
  ## Returns `true` on success, `false` if the table has no room for a new
  ## key (probe sequence exhausted without finding empty/tombstone slots).
  ## Callers should size the map generously at `init`.
  if m.slotsLen == 0:
    return false
  let
    sh = subhashOf(key)
    h = m.hashIndex(key)
  var probe: ProbeState
  while true:
    case probeForWrite(m, key, sh, h, probe)
    of prMatch:
      let slot = addr m.slots[probe.matchIdx]
      var expected = probe.matchC
      let claim = advanceControl(probe.matchC, sUpdating)
      if tryClaim(slot, expected, claim):
        slot.value = value
        slot.control.store(advanceControl(claim, sValid), moRelease)
        return true
      # CAS failed: state changed under us. Restart.
    of prInsertHere:
      let slot = addr m.slots[probe.insertIdx]
      var expected = probe.insertC
      let claim = advanceControl(probe.insertC, sClaimed)
      if tryClaim(slot, expected, claim):
        slot.subhash = sh
        slot.key = key
        slot.value = value
        slot.control.store(advanceControl(claim, sValid), moRelease)
        discard m.used.fetchAdd(1, moRelaxed)
        return true
      # CAS failed: another thread claimed this slot. Restart.
    of prFull:
      return false
    of prRetry:
      discard

proc update*[K, V](m: var LockFreeHashMap[K, V], key: K, value: V): bool =
  ## Update an existing entry. Returns `false` if the key is not present;
  ## does not insert.
  if m.slotsLen == 0:
    return false
  let
    sh = subhashOf(key)
    h = m.hashIndex(key)
  var probe: ProbeState
  while true:
    case probeForWrite(m, key, sh, h, probe)
    of prMatch:
      let slot = addr m.slots[probe.matchIdx]
      var expected = probe.matchC
      let claim = advanceControl(probe.matchC, sUpdating)
      if tryClaim(slot, expected, claim):
        slot.value = value
        slot.control.store(advanceControl(claim, sValid), moRelease)
        return true
    of prInsertHere, prFull:
      return false
    of prRetry:
      discard

proc del*[K, V](m: var LockFreeHashMap[K, V], key: auto) =
  ## Remove `key` if present. No-op if absent.
  if m.slotsLen == 0:
    return
  let
    sh = subhashOf(key)
    h = m.hashIndex(key)
  var probe: ProbeState
  while true:
    case probeForWrite(m, key, sh, h, probe)
    of prMatch:
      let slot = addr m.slots[probe.matchIdx]
      var expected = probe.matchC
      # Two-step delete via sUpdating so non-trivially-copyable K/V can be
      # reset before the slot is publicly observable as a tombstone.
      let claim = advanceControl(probe.matchC, sUpdating)
      if tryClaim(slot, expected, claim):
        when not supportsCopyMem(K):
          reset(slot.key)
        when not supportsCopyMem(V):
          reset(slot.value)
        slot.control.store(advanceControl(claim, sTombstone), moRelease)
        discard m.used.fetchAdd(-1, moRelaxed)
        return
    of prInsertHere, prFull:
      return
    of prRetry:
      discard

proc pop*[K, V](m: var LockFreeHashMap[K, V], key: auto): Opt[V] =
  ## Retrieve and remove `key`. Returns `none` if absent.
  if m.slotsLen == 0:
    return Opt.none(V)
  let
    sh = subhashOf(key)
    h = m.hashIndex(key)
  var probe: ProbeState
  while true:
    case probeForWrite(m, key, sh, h, probe)
    of prMatch:
      let slot = addr m.slots[probe.matchIdx]
      var expected = probe.matchC
      let claim = advanceControl(probe.matchC, sUpdating)
      if tryClaim(slot, expected, claim):
        let v = move(slot.value)
        when not supportsCopyMem(K):
          reset(slot.key)
        when not supportsCopyMem(V):
          reset(slot.value)
        slot.control.store(advanceControl(claim, sTombstone), moRelease)
        discard m.used.fetchAdd(-1, moRelaxed)
        return Opt.some(v)
    of prInsertHere, prFull:
      return Opt.none(V)
    of prRetry:
      discard
