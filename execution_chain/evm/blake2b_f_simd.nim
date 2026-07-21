# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## SIMD-accelerated BLAKE2b `F` compression function with a variable `rounds`
## parameter (EIP-152), transliterated to Nim from the official BLAKE2
## optimized C implementation (https://github.com/BLAKE2/BLAKE2, sse/
## directory, CC0 1.0 / OpenSSL License / Apache 2.0, Copyright 2012
## Samuel Neves). Each template below is named after the upstream C macro it
## transliterates (G1/G2 and DIAGONALIZE/UNDIAGONALIZE in blake2b-round.h,
## LOAD_MSG_<r>_<part> in blake2b-load-sse41.h), so this file can be audited
## by side-by-side comparison with the published reference source.
##
## The instruction tier is pinned per-module via `localPassC` and therefore
## does not vary with the global `-march` build settings. The SSE4.1 floor
## means Intel Penryn (2007) / AMD Bulldozer (2011) or newer — slightly above
## the SSSE3 baseline the distribution builds assume (config.nims passes
## `-mssse3` globally when `-d:disableMarchNative`), but the only CPUs in
## that gap are 2006-era Core 2 and pre-2013 Atoms.

{.push raises: [].}

when defined(amd64):
  import nimcrypto/utils

  const blake2bSimdAvailable* = true

  when defined(vcc):
    {.pragma: x86type, bycopy, header: "<intrin.h>".}
    {.pragma: x86proc, nodecl, header: "<intrin.h>".}
  else:
    {.localPassC: "-mssse3 -msse4.1".}
    {.pragma: x86type, bycopy, header: "<x86intrin.h>".}
    {.pragma: x86proc, nodecl, header: "<x86intrin.h>".}

  type
    M128i {.importc: "__m128i", x86type.} = object
      data: array[2, uint64]

  func mm_loadu_si128(p: pointer): M128i {.
       importc: "_mm_loadu_si128", x86proc.}
  func mm_storeu_si128(p: pointer, a: M128i) {.
       importc: "_mm_storeu_si128", x86proc.}
  func mm_set_epi64x(e1, e0: uint64): M128i {.
       importc: "_mm_set_epi64x", x86proc.}
  func mm_setr_epi8(e0, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12,
                    e13, e14, e15: int8): M128i {.
       importc: "_mm_setr_epi8", x86proc.}
  func mm_add_epi64(a, b: M128i): M128i {.
       importc: "_mm_add_epi64", x86proc.}
  func mm_xor_si128(a, b: M128i): M128i {.
       importc: "_mm_xor_si128", x86proc.}
  func mm_srli_epi64(a: M128i, imm8: int32): M128i {.
       importc: "_mm_srli_epi64", x86proc.}
  func mm_shuffle_epi32(a: M128i, imm8: int32): M128i {.
       importc: "_mm_shuffle_epi32", x86proc.}
  func mm_shuffle_epi8(a, b: M128i): M128i {.
       importc: "_mm_shuffle_epi8", x86proc.}
  func mm_alignr_epi8(a, b: M128i, imm8: int32): M128i {.
       importc: "_mm_alignr_epi8", x86proc.}
  func mm_unpacklo_epi64(a, b: M128i): M128i {.
       importc: "_mm_unpacklo_epi64", x86proc.}
  func mm_unpackhi_epi64(a, b: M128i): M128i {.
       importc: "_mm_unpackhi_epi64", x86proc.}
  func mm_blend_epi16(a, b: M128i, imm8: int32): M128i {.
       importc: "_mm_blend_epi16", x86proc.}

  const B2BIV = [
    0x6A09E667F3BCC908'u64, 0xBB67AE8584CAA73B'u64,
    0x3C6EF372FE94F82B'u64, 0xA54FF53A5F1D36F1'u64,
    0x510E527FADE682D1'u64, 0x9B05688C2B3E6C1F'u64,
    0x1F83D9ABFB41BD6B'u64, 0x5BE0CD19137E2179'u64
  ]

  proc blake2bCompress(rounds: uint32, h: var array[8, uint64],
                       m: array[16, uint64], t: array[2, uint64],
                       last: bool) =
    var
      row1l = mm_loadu_si128(addr h[0])
      row1h = mm_loadu_si128(addr h[2])
      row2l = mm_loadu_si128(addr h[4])
      row2h = mm_loadu_si128(addr h[6])
      row3l = mm_set_epi64x(B2BIV[1], B2BIV[0])
      row3h = mm_set_epi64x(B2BIV[3], B2BIV[2])
      row4l = mm_xor_si128(mm_set_epi64x(B2BIV[5], B2BIV[4]),
                           mm_set_epi64x(t[1], t[0]))
      row4h = mm_xor_si128(mm_set_epi64x(B2BIV[7], B2BIV[6]),
                           mm_set_epi64x(0'u64,
                             if last: high(uint64) else: 0'u64))
      b0, b1, t0, t1: M128i

    let
      # amd64 is little-endian, so the uint64 array has the same byte layout
      # as the original 128-byte message block the C code loads from.
      mm0 = mm_loadu_si128(unsafeAddr m[0])
      mm1 = mm_loadu_si128(unsafeAddr m[2])
      mm2 = mm_loadu_si128(unsafeAddr m[4])
      mm3 = mm_loadu_si128(unsafeAddr m[6])
      mm4 = mm_loadu_si128(unsafeAddr m[8])
      mm5 = mm_loadu_si128(unsafeAddr m[10])
      mm6 = mm_loadu_si128(unsafeAddr m[12])
      mm7 = mm_loadu_si128(unsafeAddr m[14])
      r16 = mm_setr_epi8(2, 3, 4, 5, 6, 7, 0, 1, 10, 11, 12, 13, 14, 15, 8, 9)
      r24 = mm_setr_epi8(3, 4, 5, 6, 7, 0, 1, 2, 11, 12, 13, 14, 15, 8, 9, 10)

    # 64-bit lane rotations; 32 uses a dword shuffle, 24/16 a byte shuffle
    # (SSSE3), 63 the shift/add trick — mirrors _mm_roti_epi64 in
    # blake2b-round.h.
    template rot32(x: M128i): M128i = mm_shuffle_epi32(x, 0xB1)
    template rot24(x: M128i): M128i = mm_shuffle_epi8(x, r24)
    template rot16(x: M128i): M128i = mm_shuffle_epi8(x, r16)
    template rot63(x: M128i): M128i =
      mm_xor_si128(mm_srli_epi64(x, 63), mm_add_epi64(x, x))

    template unlo(a, b: M128i): M128i = mm_unpacklo_epi64(a, b)
    template unhi(a, b: M128i): M128i = mm_unpackhi_epi64(a, b)
    template blend(a, b: M128i): M128i = mm_blend_epi16(a, b, 0xF0)
    template align8(a, b: M128i): M128i = mm_alignr_epi8(a, b, 8)
    template swap32(a: M128i): M128i =
      mm_shuffle_epi32(a, 0x4E) # _MM_SHUFFLE(1,0,3,2)

    # Message schedule per round, from blake2b-load-sse41.h
    # (LOAD_MSG_<r>_<part>). Rounds 10/11 repeat rounds 0/1, so only ten
    # variants are needed for the mod-10 round loop.
    template loadMsg(r, part: static int) =
      when r == 0:
        when part == 1: b0 = unlo(mm0, mm1); b1 = unlo(mm2, mm3)
        elif part == 2: b0 = unhi(mm0, mm1); b1 = unhi(mm2, mm3)
        elif part == 3: b0 = unlo(mm4, mm5); b1 = unlo(mm6, mm7)
        else:           b0 = unhi(mm4, mm5); b1 = unhi(mm6, mm7)
      elif r == 1:
        when part == 1: b0 = unlo(mm7, mm2); b1 = unhi(mm4, mm6)
        elif part == 2: b0 = unlo(mm5, mm4); b1 = align8(mm3, mm7)
        elif part == 3: b0 = swap32(mm0);    b1 = unhi(mm5, mm2)
        else:           b0 = unlo(mm6, mm1); b1 = unhi(mm3, mm1)
      elif r == 2:
        when part == 1: b0 = align8(mm6, mm5); b1 = unhi(mm2, mm7)
        elif part == 2: b0 = unlo(mm4, mm0);   b1 = blend(mm1, mm6)
        elif part == 3: b0 = blend(mm5, mm1);  b1 = unhi(mm3, mm4)
        else:           b0 = unlo(mm7, mm3);   b1 = align8(mm2, mm0)
      elif r == 3:
        when part == 1: b0 = unhi(mm3, mm1); b1 = unhi(mm6, mm5)
        elif part == 2: b0 = unhi(mm4, mm0); b1 = unlo(mm6, mm7)
        elif part == 3: b0 = blend(mm1, mm2); b1 = blend(mm2, mm7)
        else:           b0 = unlo(mm3, mm5);  b1 = unlo(mm0, mm4)
      elif r == 4:
        when part == 1: b0 = unhi(mm4, mm2); b1 = unlo(mm1, mm5)
        elif part == 2: b0 = blend(mm0, mm3); b1 = blend(mm2, mm7)
        elif part == 3: b0 = blend(mm7, mm5); b1 = blend(mm3, mm1)
        else:           b0 = align8(mm6, mm0); b1 = blend(mm4, mm6)
      elif r == 5:
        when part == 1: b0 = unlo(mm1, mm3); b1 = unlo(mm0, mm4)
        elif part == 2: b0 = unlo(mm6, mm5); b1 = unhi(mm5, mm1)
        elif part == 3: b0 = blend(mm2, mm3); b1 = unhi(mm7, mm0)
        else:           b0 = unhi(mm6, mm2);  b1 = blend(mm7, mm4)
      elif r == 6:
        when part == 1: b0 = blend(mm6, mm0); b1 = unlo(mm7, mm2)
        elif part == 2: b0 = unhi(mm2, mm7);  b1 = align8(mm5, mm6)
        elif part == 3: b0 = unlo(mm0, mm3);  b1 = swap32(mm4)
        else:           b0 = unhi(mm3, mm1);  b1 = blend(mm1, mm5)
      elif r == 7:
        when part == 1: b0 = unhi(mm6, mm3);  b1 = blend(mm6, mm1)
        elif part == 2: b0 = align8(mm7, mm5); b1 = unhi(mm0, mm4)
        elif part == 3: b0 = unhi(mm2, mm7);  b1 = unlo(mm4, mm1)
        else:           b0 = unlo(mm0, mm2);  b1 = unlo(mm3, mm5)
      elif r == 8:
        when part == 1: b0 = unlo(mm3, mm7); b1 = align8(mm0, mm5)
        elif part == 2: b0 = unhi(mm7, mm4); b1 = align8(mm4, mm1)
        elif part == 3: b0 = mm6;            b1 = align8(mm5, mm0)
        else:           b0 = blend(mm1, mm3); b1 = mm2
      else:
        when part == 1: b0 = unlo(mm5, mm4); b1 = unhi(mm3, mm0)
        elif part == 2: b0 = unlo(mm1, mm2); b1 = blend(mm3, mm2)
        elif part == 3: b0 = unhi(mm7, mm4); b1 = unhi(mm1, mm6)
        else:           b0 = align8(mm7, mm5); b1 = unlo(mm6, mm0)

    template g1() =
      row1l = mm_add_epi64(mm_add_epi64(row1l, b0), row2l)
      row1h = mm_add_epi64(mm_add_epi64(row1h, b1), row2h)
      row4l = rot32(mm_xor_si128(row4l, row1l))
      row4h = rot32(mm_xor_si128(row4h, row1h))
      row3l = mm_add_epi64(row3l, row4l)
      row3h = mm_add_epi64(row3h, row4h)
      row2l = rot24(mm_xor_si128(row2l, row3l))
      row2h = rot24(mm_xor_si128(row2h, row3h))

    template g2() =
      row1l = mm_add_epi64(mm_add_epi64(row1l, b0), row2l)
      row1h = mm_add_epi64(mm_add_epi64(row1h, b1), row2h)
      row4l = rot16(mm_xor_si128(row4l, row1l))
      row4h = rot16(mm_xor_si128(row4h, row1h))
      row3l = mm_add_epi64(row3l, row4l)
      row3h = mm_add_epi64(row3h, row4h)
      row2l = rot63(mm_xor_si128(row2l, row3l))
      row2h = rot63(mm_xor_si128(row2h, row3h))

    template diagonalize() =
      t0 = align8(row2h, row2l)
      t1 = align8(row2l, row2h)
      row2l = t0
      row2h = t1
      t0 = row3l
      row3l = row3h
      row3h = t0
      t0 = align8(row4h, row4l)
      t1 = align8(row4l, row4h)
      row4l = t1
      row4h = t0

    template undiagonalize() =
      t0 = align8(row2l, row2h)
      t1 = align8(row2h, row2l)
      row2l = t0
      row2h = t1
      t0 = row3l
      row3l = row3h
      row3h = t0
      t0 = align8(row4l, row4h)
      t1 = align8(row4h, row4l)
      row4l = t1
      row4h = t0

    template roundT(r: static int) =
      loadMsg(r, 1)
      g1()
      loadMsg(r, 2)
      g2()
      diagonalize()
      loadMsg(r, 3)
      g1()
      loadMsg(r, 4)
      g2()
      undiagonalize()

    var n = 0
    for _ in 0 ..< rounds:
      case n
      of 0: roundT(0)
      of 1: roundT(1)
      of 2: roundT(2)
      of 3: roundT(3)
      of 4: roundT(4)
      of 5: roundT(5)
      of 6: roundT(6)
      of 7: roundT(7)
      of 8: roundT(8)
      else: roundT(9)
      inc n
      if n == 10: n = 0

    row1l = mm_xor_si128(row3l, row1l)
    row1h = mm_xor_si128(row3h, row1h)
    mm_storeu_si128(addr h[0],
      mm_xor_si128(mm_loadu_si128(addr h[0]), row1l))
    mm_storeu_si128(addr h[2],
      mm_xor_si128(mm_loadu_si128(addr h[2]), row1h))
    row2l = mm_xor_si128(row4l, row2l)
    row2h = mm_xor_si128(row4h, row2h)
    mm_storeu_si128(addr h[4],
      mm_xor_si128(mm_loadu_si128(addr h[4]), row2l))
    mm_storeu_si128(addr h[6],
      mm_xor_si128(mm_loadu_si128(addr h[6]), row2h))

  # Same interface and EIP-152 input validation/parsing as blake2b_F_nim in
  # blake2b_f.nim: input is exactly 213 bytes, output accomodates 64 bytes.
  proc blake2b_F_simd*(input: openArray[byte],
                       output: var openArray[byte]): bool =
    if input.len != 213:
      return false

    if input[212] notin {byte(0), byte(1)}:
      return false

    var
      h: array[8, uint64]
      m: array[16, uint64]
      t: array[2, uint64]

    let
      rounds = beLoad32(input, 0)
      last   = input[212] == byte(1)

    for i in 0 ..< 8:
      h[i] = leLoad64(input, 4 + i * 8)
    for i in 0 ..< 16:
      m[i] = leLoad64(input, 68 + i * 8)
    t[0] = leLoad64(input, 196)
    t[1] = leLoad64(input, 204)

    blake2bCompress(rounds, h, m, t, last)

    for i in 0 ..< 8:
      leStore64(output, i * 8, h[i])
    result = true

else:
  const blake2bSimdAvailable* = false

{.pop.}
