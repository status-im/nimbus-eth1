# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Keccak-256, with the permutation structured in the style of XKCP's
## `KeccakP-1600-opt64.c`.
##
## Lanes are indexed `x + 5*y`. A round reads one 25-lane state and writes the
## other, so nothing is written back mid-round and the 24 rotations are
## independent of each other rather than forming a serial chain. Rounds
## alternate `a -> e -> a`, and 24 being even leaves the result in `a`.
##
## The templates take lane indices and rotation offsets as arguments so they
## remain compile-time literals: `d[s mod 5]` folds to a constant index and each
## rotation folds to an immediate. Written as loops over runtime `x`/`y` the
## offsets would become table lookups instead.
##
## Little-endian only, matching nim-eth's `keccak.c`, whose `CRYPTO_load_u64_le`
## does no byte swapping despite the name.

{.push raises: [], gcsafe, checks: off.}

const
  RateBytes* = 200 - (512 div 8)
    ## Keccak-256 block size

const kRC: array[24, uint64] = [
  0x0000000000000001'u64, 0x0000000000008082'u64, 0x800000000000808a'u64,
  0x8000000080008000'u64, 0x000000000000808b'u64, 0x0000000080000001'u64,
  0x8000000080008081'u64, 0x8000000000008009'u64, 0x000000000000008a'u64,
  0x0000000000000088'u64, 0x0000000080008009'u64, 0x000000008000000a'u64,
  0x000000008000808b'u64, 0x800000000000008b'u64, 0x8000000000008089'u64,
  0x8000000000008003'u64, 0x8000000000008002'u64, 0x8000000000000080'u64,
  0x000000000000800a'u64, 0x800000008000000a'u64, 0x8000000080008081'u64,
  0x8000000000008080'u64, 0x0000000080000001'u64, 0x8000000080008008'u64,
]

template rotl64(v, s: untyped): uint64 =
  ## `s` is a literal at every call site. Lane 0 has an offset of 0, where a
  ## shift by 64 would be undefined.
  when s == 0: v
  else: (v shl s) or (v shr (64 - s))

template theta1(c, a: untyped) =
  ## Column parities.
  c[0] = a[0] xor a[5] xor a[10] xor a[15] xor a[20]
  c[1] = a[1] xor a[6] xor a[11] xor a[16] xor a[21]
  c[2] = a[2] xor a[7] xor a[12] xor a[17] xor a[22]
  c[3] = a[3] xor a[8] xor a[13] xor a[18] xor a[23]
  c[4] = a[4] xor a[9] xor a[14] xor a[19] xor a[24]

template theta2(d, c: untyped) =
  ## Value each lane in column x gets mixed with.
  d[0] = c[4] xor rotl64(c[1], 1)
  d[1] = c[0] xor rotl64(c[2], 1)
  d[2] = c[1] xor rotl64(c[3], 1)
  d[3] = c[2] xor rotl64(c[4], 1)
  d[4] = c[3] xor rotl64(c[0], 1)

template pichi(dst, src, d, b: untyped,
               o, s0, r0, s1, r1, s2, r2, s3, r3, s4, r4: untyped) =
  ## One output row: rho and pi rotate five source lanes into `b`, with theta's
  ## diffusion folded in, then chi combines them into `dst[o .. o+4]`.
  b[0] = rotl64(src[s0] xor d[s0 mod 5], r0)
  b[1] = rotl64(src[s1] xor d[s1 mod 5], r1)
  b[2] = rotl64(src[s2] xor d[s2 mod 5], r2)
  b[3] = rotl64(src[s3] xor d[s3 mod 5], r3)
  b[4] = rotl64(src[s4] xor d[s4 mod 5], r4)
  dst[o] = b[0] xor (not(b[1]) and b[2])
  dst[o + 1] = b[1] xor (not(b[2]) and b[3])
  dst[o + 2] = b[2] xor (not(b[3]) and b[4])
  dst[o + 3] = b[3] xor (not(b[4]) and b[0])
  dst[o + 4] = b[4] xor (not(b[0]) and b[1])

template keccakRound(src, dst, c, d: untyped, rc: uint64) =
  theta1(c, src)
  theta2(d, c)

  # `c` is dead once `d` is built, so it doubles as the per-row scratch.
  # Each row lists its five source lanes paired with their rho offsets.
  pichi(dst, src, d, c,  0,  0,  0,  6, 44, 12, 43, 18, 21, 24, 14)
  pichi(dst, src, d, c,  5,  3, 28,  9, 20, 10,  3, 16, 45, 22, 61)
  pichi(dst, src, d, c, 10,  1,  1,  7,  6, 13, 25, 19,  8, 20, 18)
  pichi(dst, src, d, c, 15,  4, 27,  5, 36, 11, 10, 17, 15, 23, 56)
  pichi(dst, src, d, c, 20,  2, 62,  8, 55, 14, 39, 15, 41, 21,  2)

  dst[0] = dst[0] xor rc

func keccakF(state: var array[25, uint64]) =
  var
    a {.noinit.}: array[25, uint64]
    e {.noinit.}: array[25, uint64]
    c {.noinit.}: array[5, uint64]
    d {.noinit.}: array[5, uint64]

  a = state

  var r = 0
  while r < 24:
    keccakRound(a, e, c, d, kRC[r])
    keccakRound(e, a, c, d, kRC[r + 1])
    r += 2

  state = a

func keccak256XkcpNim*(input: openArray[byte], output: var array[32, byte]) =
  ## One-shot Keccak-256 (the original 0x01 padding, not SHA-3's 0x06).
  var state: array[25, uint64]
  let stateBytes = cast[ptr UncheckedArray[byte]](addr state[0])
  var
    pos = 0
    remaining = input.len

  while remaining >= RateBytes:
    for i in 0 ..< RateBytes div 8:
      var v: uint64
      copyMem(addr v, unsafeAddr input[pos + 8 * i], 8)
      state[i] = state[i] xor v
    keccakF(state)
    pos += RateBytes
    remaining -= RateBytes

  for i in 0 ..< remaining:
    stateBytes[i] = stateBytes[i] xor input[pos + i]
  stateBytes[remaining] = stateBytes[remaining] xor 0x01'u8
  stateBytes[RateBytes - 1] = stateBytes[RateBytes - 1] xor 0x80'u8
  keccakF(state)
  copyMem(addr output[0], addr state[0], 32)

{.pop.}
