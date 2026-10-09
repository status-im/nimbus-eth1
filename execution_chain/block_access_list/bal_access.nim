# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

# Insertion-ordered set of accessed keys for one transaction. Buckets hold an
# epoch in the high bits and a key position in the low bits, so a reset is a
# bump of the epoch rather than a clear, and the keys stay in a flat seq that
# can be handed to the builder in one copy.

import
  std/bitops,
  eth/common/addresses,
  stint,
  ./bal_builder

export AccessedSlot

type
  AccessSet*[K] = object
    keys*: seq[K]
    buckets: seq[uint64]
    epoch: uint64
    shift: int

const
  epochStep = 1'u64 shl 32
  indexMask = epochStep - 1
  epochMask = not indexMask

func hashKey(a: Address): uint64 {.inline.} =
  let p = cast[ptr UncheckedArray[byte]](unsafeAddr a)
  var
    x, y: uint64
    z: uint32
  copyMem(addr x, addr p[0], 8)
  copyMem(addr y, addr p[8], 8)
  copyMem(addr z, addr p[16], 4)
  let h =
    x xor (y * 0x9E3779B97F4A7C15'u64) xor (uint64(z) * 0xC2B2AE3D27D4EB4F'u64)
  (h xor (h shr 31)) * 0x94D049BB133111EB'u64

func hashKey(k: AccessedSlot): uint64 {.inline.} =
  let
    l = k.slot.limbs
    s =
      (l[0] * 0x9E3779B97F4A7C15'u64) xor (l[1] * 0xC2B2AE3D27D4EB4F'u64) xor
      (l[2] * 0x165667B19E3779F9'u64) xor (l[3] * 0xD6E8FEB86659FD93'u64)
    h = hashKey(k.address) xor s
  (h xor (h shr 29)) * 0xBF58476D1CE4E5B9'u64

func grow[K](s: var AccessSet[K]) {.noinline.} =
  let size = max(32, s.buckets.len * 2)
  s.buckets = newSeq[uint64](size)
  s.shift = 64 - fastLog2(size)
  if s.epoch == 0:
    s.epoch = epochStep
  let mask = size - 1
  for idx in 0 ..< s.keys.len:
    var i = int(hashKey(s.keys[idx]) shr s.shift)
    while (s.buckets[i] and epochMask) == s.epoch:
      i = (i + 1) and mask
    s.buckets[i] = s.epoch or uint64(idx + 1)

func reset*[K](s: var AccessSet[K]) =
  s.keys.setLen(0)
  s.epoch += epochStep
  if s.epoch == 0:
    s.epoch = epochStep
    if s.buckets.len > 0:
      zeroMem(addr s.buckets[0], s.buckets.len * sizeof(uint64))

func incl*[K](s: var AccessSet[K], key: K) {.inline.} =
  if s.keys.len * 2 >= s.buckets.len:
    s.grow()
  let
    mask = s.buckets.len - 1
    buckets = cast[ptr UncheckedArray[uint64]](addr s.buckets[0])
  var i = int(hashKey(key) shr s.shift)
  while true:
    let b = buckets[i]
    if (b and epochMask) != s.epoch:
      buckets[i] = s.epoch or uint64(s.keys.len + 1)
      s.keys.add key
      return
    if s.keys[int(b and indexMask) - 1] == key:
      return
    i = (i + 1) and mask

func find*[K](s: AccessSet[K], key: K): int =
  ## Position of `key` in `keys`, or -1.
  if s.buckets.len == 0:
    return -1
  let mask = s.buckets.len - 1
  var i = int(hashKey(key) shr s.shift)
  while true:
    let b = s.buckets[i]
    if (b and epochMask) != s.epoch:
      return -1
    let idx = int(b and indexMask) - 1
    if s.keys[idx] == key:
      return idx
    i = (i + 1) and mask
