# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [], gcsafe.}

import std/[bitops, hashes, math, typetraits], results
from system/ansi_c import c_memset

export hashes, results

const
  ctrlEmpty = 0x80'u8
  ctrlDeleted = 0xFE'u8
  useSimd = defined(amd64) and not defined(swissTableNoSimd)

when useSimd:
  {.pragma: sse2, header: "emmintrin.h".}

  type Group {.importc: "__m128i", sse2, bycopy.} = object

  proc mmLoadu(p: ptr Group): Group {.importc: "_mm_loadu_si128", sse2.}
  proc mmSet1(b: int8): Group {.importc: "_mm_set1_epi8", sse2.}
  proc mmCmpeq(a, b: Group): Group {.importc: "_mm_cmpeq_epi8", sse2.}
  proc mmMovemask(a: Group): int32 {.importc: "_mm_movemask_epi8", sse2.}

  const
    groupWidth = 16
    matchShift = 0

  template loadGroup(p: ptr byte): Group =
    mmLoadu(cast[ptr Group](p))

  template matchTag(g: Group, tag: uint8): uint64 =
    uint64(cast[uint32](mmMovemask(mmCmpeq(g, mmSet1(cast[int8](tag))))))

  template matchEmpty(g: Group): uint64 =
    uint64(cast[uint32](mmMovemask(mmCmpeq(g, mmSet1(cast[int8](ctrlEmpty))))))

  template matchFree(g: Group): uint64 =
    uint64(cast[uint32](mmMovemask(g)))

else:
  const
    groupWidth = 8
    matchShift = 3
    lsbs = 0x0101010101010101'u64
    msbs = 0x8080808080808080'u64

  type Group = uint64

  template loadGroup(p: ptr byte): Group =
    block:
      var g: uint64
      copyMem(addr g, p, sizeof(uint64))
      g

  template matchTag(g: Group, tag: uint8): uint64 =
    block:
      let cmp = g xor (lsbs * uint64(tag))
      (cmp - lsbs) and (not cmp) and msbs

  template matchEmpty(g: Group): uint64 =
    g and ((not g) shl 1) and msbs

  template matchFree(g: Group): uint64 =
    g and msbs

type
  SwissEntry[K, V] = object
    key: K
    value: V

  SwissTable*[K, V] = object
    slots: ptr UncheckedArray[SwissEntry[K, V]]
    ctrl: ptr UncheckedArray[byte]
    capacity: int
    used: int
    growthLeft: int

when defined(gcc) or defined(clang) or defined(llvm_gcc):
  proc builtinPrefetch(p: pointer) {.importc: "__builtin_prefetch", nodecl.}

  template prefetch(p: pointer) =
    builtinPrefetch(p)

else:
  template prefetch(p: pointer) =
    discard

const minCapacity = groupWidth

template maxLoad(capacity: int): int =
  capacity - (capacity shr 3)

template h1(h: Hash): uint =
  cast[uint](h) shr 7

template tagOf(h: Hash): uint8 =
  uint8(cast[uint](h) and 0x7f'u)

template hashOf(key: untyped): Hash =
  mixin hash
  hash(key)

template isFull(b: uint8): bool =
  (b and 0x80'u8) == 0'u8

template firstSlot(m: uint64): uint =
  uint(countTrailingZeroBits(m) shr matchShift)

template lastSlot(m: uint64): uint =
  uint(fastLog2(m) shr matchShift)

template dropSlot(m: uint64): uint64 =
  m and (m - 1)

proc allocSlots[K, V](s: var SwissTable[K, V], capacity: int) =
  let
    slotBytes = capacity * sizeof(SwissEntry[K, V])
    totalBytes = slotBytes + capacity + groupWidth
    mem = cast[ptr UncheckedArray[byte]](allocShared(totalBytes))

  s.slots = cast[ptr UncheckedArray[SwissEntry[K, V]]](mem)
  s.ctrl = cast[ptr UncheckedArray[byte]](addr mem[slotBytes])
  s.capacity = capacity
  s.growthLeft = maxLoad(capacity)
  discard c_memset(s.ctrl, cint(ctrlEmpty), csize_t(capacity + groupWidth))

proc setCtrl[K, V](s: var SwissTable[K, V], i: uint, b: uint8) {.inline.} =
  let mask = uint(s.capacity) - 1
  s.ctrl[i] = b
  s.ctrl[((i - uint(groupWidth)) and mask) + uint(groupWidth)] = b

func findEntry[K, V](s: SwissTable[K, V], h: Hash, key: K): int =
  mixin `==`

  if s.capacity == 0:
    return -1

  let
    mask = uint(s.capacity) - 1
    tag = tagOf(h)
  var
    pos = h1(h) and mask
    stride = 0'u

  while true:
    prefetch(addr s.slots[pos])
    let g = loadGroup(addr s.ctrl[pos])
    var m = matchTag(g, tag)
    while m != 0:
      let i = (pos + firstSlot(m)) and mask
      if s.slots[i].key == key:
        return int(i)
      m = dropSlot(m)

    if matchEmpty(g) != 0:
      return -1

    stride += uint(groupWidth)
    pos = (pos + stride) and mask

func findOrPrepare[K, V](
    s: SwissTable[K, V], h: Hash, key: K
): tuple[found: int, free: uint] =
  mixin `==`

  let
    mask = uint(s.capacity) - 1
    tag = tagOf(h)
  var
    pos = h1(h) and mask
    stride = 0'u
    free = -1

  while true:
    prefetch(addr s.slots[pos])
    let g = loadGroup(addr s.ctrl[pos])
    var m = matchTag(g, tag)
    while m != 0:
      let i = (pos + firstSlot(m)) and mask
      if s.slots[i].key == key:
        return (int(i), 0'u)
      m = dropSlot(m)

    let f = matchFree(g)
    if matchEmpty(g) != 0:
      if free < 0:
        free = int((pos + firstSlot(f)) and mask)
      return (-1, uint(free))

    if free < 0 and f != 0:
      free = int((pos + firstSlot(f)) and mask)

    stride += uint(groupWidth)
    pos = (pos + stride) and mask

func findFreeSlot[K, V](s: SwissTable[K, V], h: Hash): uint =
  let mask = uint(s.capacity) - 1
  var
    pos = h1(h) and mask
    stride = 0'u

  while true:
    let
      g = loadGroup(addr s.ctrl[pos])
      m = matchFree(g)
    if m != 0:
      return (pos + firstSlot(m)) and mask

    stride += uint(groupWidth)
    pos = (pos + stride) and mask

proc resizeTo[K, V](s: var SwissTable[K, V], capacity: int) =
  let
    oldSlots = s.slots
    oldCtrl = s.ctrl
    oldCapacity = s.capacity

  s.allocSlots(capacity)

  for i in 0 ..< oldCapacity:
    if isFull(oldCtrl[i]):
      let
        h = hashOf(oldSlots[i].key)
        j = s.findFreeSlot(h)
      s.setCtrl(j, tagOf(h))
      s.slots[j].key = oldSlots[i].key
      s.slots[j].value = move(oldSlots[i].value)
      s.growthLeft -= 1

  if oldCapacity > 0:
    deallocShared(oldSlots)

proc makeRoom[K, V](s: var SwissTable[K, V]) =
  if s.capacity == 0:
    s.allocSlots(minCapacity)
  elif s.used * 2 <= s.capacity:
    s.resizeTo(s.capacity)
  else:
    s.resizeTo(s.capacity * 2)

proc init*[K, V](T: type SwissTable[K, V], initialSize: int = 0): T =
  static:
    doAssert supportsCopyMem(K), "K must be a non-GC type"

  if initialSize > 0:
    let capacity =
      max(minCapacity, nextPowerOfTwo(initialSize + (initialSize + 6) div 7))
    result.allocSlots(capacity)

proc dispose*[K, V](s: var SwissTable[K, V]) =
  if s.capacity > 0:
    deallocShared(s.slots)
    s.slots = nil
    s.ctrl = nil
    s.capacity = 0
    s.used = 0
    s.growthLeft = 0

proc `=copy`*[K, V](
    dest: var SwissTable[K, V], src: SwissTable[K, V]
) {.error: "Copying SwissTable is forbidden".} =
  discard

template len*[K, V](s: SwissTable[K, V]): int =
  s.used

func contains*[K, V](s: SwissTable[K, V], key: K): bool =
  s.findEntry(hashOf(key), key) >= 0

func get*[K, V](s: SwissTable[K, V], key: K): Opt[V] =
  let i = s.findEntry(hashOf(key), key)
  if i >= 0:
    Opt.some(s.slots[i].value)
  else:
    Opt.none(V)

template `[]`*[K, V](s: SwissTable[K, V], key: K): Opt[V] =
  s.get(key)

func getOrDefault*[K, V](s: SwissTable[K, V], key: K): V =
  let i = s.findEntry(hashOf(key), key)
  if i >= 0:
    s.slots[i].value
  else:
    default(V)

func getOrDefault*[K, V](s: SwissTable[K, V], key: K, default: V): V =
  let i = s.findEntry(hashOf(key), key)
  if i >= 0:
    s.slots[i].value
  else:
    default

proc put*[K, V](s: var SwissTable[K, V], key: K, value: sink V) =
  let h = hashOf(key)

  if s.capacity == 0:
    s.makeRoom()

  let (existing, free) = s.findOrPrepare(h, key)
  if existing >= 0:
    s.slots[existing].value = move(value)
    return

  var i = free
  if s.growthLeft == 0:
    s.makeRoom()
    i = s.findFreeSlot(h)

  let wasEmpty = s.ctrl[i] == ctrlEmpty
  s.setCtrl(i, tagOf(h))
  s.slots[i].key = key
  s.slots[i].value = move(value)
  s.used += 1
  if wasEmpty:
    s.growthLeft -= 1

template `[]=`*(s: var SwissTable, key, value: untyped) =
  s.put(key, value)

proc eraseAt[K, V](s: var SwissTable[K, V], i: uint) =
  let
    mask = uint(s.capacity) - 1
    before = (i - uint(groupWidth)) and mask
    emptyBefore = matchEmpty(loadGroup(addr s.ctrl[before]))
    emptyAfter = matchEmpty(loadGroup(addr s.ctrl[i]))
    reclaim =
      emptyBefore != 0 and emptyAfter != 0 and
      firstSlot(emptyAfter) + (uint(groupWidth) - 1 - lastSlot(emptyBefore)) <
        uint(groupWidth)

  if reclaim:
    s.setCtrl(i, ctrlEmpty)
    s.growthLeft += 1
  else:
    s.setCtrl(i, ctrlDeleted)
  s.used -= 1

proc del*[K, V](s: var SwissTable[K, V], key: K): bool {.discardable.} =
  let i = s.findEntry(hashOf(key), key)
  if i < 0:
    return false

  s.eraseAt(uint(i))
  true

proc pop*[K, V](s: var SwissTable[K, V], key: K): Opt[V] =
  let i = s.findEntry(hashOf(key), key)
  if i < 0:
    return Opt.none(V)

  result = Opt.some(move(s.slots[i].value))
  s.eraseAt(uint(i))

proc clear*[K, V](s: var SwissTable[K, V]) =
  if s.capacity > 0:
    discard c_memset(s.ctrl, cint(ctrlEmpty), csize_t(s.capacity + groupWidth))
    s.growthLeft = maxLoad(s.capacity)
  s.used = 0

template withValue*[K, V](s: var SwissTable[K, V], key: K, val, body: untyped) =
  let idx = s.findEntry(hashOf(key), key)
  if idx >= 0:
    let val {.inject.} = addr s.slots[idx].value
    body

template withValue*[K, V](
    s: var SwissTable[K, V], key: K, val, body1, body2: untyped
) =
  let idx = s.findEntry(hashOf(key), key)
  if idx >= 0:
    let val {.inject.} = addr s.slots[idx].value
    body1
  else:
    body2

iterator keys*[K, V](s: SwissTable[K, V]): lent K =
  for i in 0 ..< s.capacity:
    if isFull(s.ctrl[i]):
      yield s.slots[i].key

iterator values*[K, V](s: SwissTable[K, V]): lent V =
  for i in 0 ..< s.capacity:
    if isFull(s.ctrl[i]):
      yield s.slots[i].value

iterator mvalues*[K, V](s: var SwissTable[K, V]): var V =
  for i in 0 ..< s.capacity:
    if isFull(s.ctrl[i]):
      yield s.slots[i].value

iterator pairs*[K, V](s: SwissTable[K, V]): (lent K, lent V) =
  for i in 0 ..< s.capacity:
    if isFull(s.ctrl[i]):
      yield (s.slots[i].key, s.slots[i].value)

iterator mpairs*[K, V](s: var SwissTable[K, V]): (lent K, var V) =
  for i in 0 ..< s.capacity:
    if isFull(s.ctrl[i]):
      yield (s.slots[i].key, s.slots[i].value)
