import nimcrypto/utils

# Blake2 `F` compression function
# taken from nimcrypto with modification

# in nimcrypto, blake2 compression function `F`
# is hardcoded for blake2b and blake2s
# we need a generic `F` function with
# `rounds` parameter

type
  Blake2bContext = object
    h: array[8, uint64]
    t: array[2, uint64]

const Sigma = [
  [0'u8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14'u8, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  [11'u8, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
  [7'u8, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
  [9'u8, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
  [2'u8, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
  [12'u8, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
  [13'u8, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
  [6'u8, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
  [10'u8, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
  [0'u8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14'u8, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3]
]

const B2BIV = [
  0x6A09E667F3BCC908'u64, 0xBB67AE8584CAA73B'u64,
  0x3C6EF372FE94F82B'u64, 0xA54FF53A5F1D36F1'u64,
  0x510E527FADE682D1'u64, 0x9B05688C2B3E6C1F'u64,
  0x1F83D9ABFB41BD6B'u64, 0x5BE0CD19137E2179'u64
]

template B2B_G(v, a, b, c, d, x, y: untyped) =
  v[a] = v[a] + v[b] + x
  v[d] = ROR(v[d] xor v[a], 32)
  v[c] = v[c] + v[d]
  v[b] = ROR(v[b] xor v[c], 24)
  v[a] = v[a] + v[b] + y
  v[d] = ROR(v[d] xor v[a], 16)
  v[c] = v[c] + v[d]
  v[b] = ROR(v[b] xor v[c], 63)

template B2BROUND(v, m, n: untyped) =
  B2B_G(v, 0, 4,  8, 12, m[Sigma[n][ 0]], m[Sigma[n][ 1]])
  B2B_G(v, 1, 5,  9, 13, m[Sigma[n][ 2]], m[Sigma[n][ 3]])
  B2B_G(v, 2, 6, 10, 14, m[Sigma[n][ 4]], m[Sigma[n][ 5]])
  B2B_G(v, 3, 7, 11, 15, m[Sigma[n][ 6]], m[Sigma[n][ 7]])
  B2B_G(v, 0, 5, 10, 15, m[Sigma[n][ 8]], m[Sigma[n][ 9]])
  B2B_G(v, 1, 6, 11, 12, m[Sigma[n][10]], m[Sigma[n][11]])
  B2B_G(v, 2, 7,  8, 13, m[Sigma[n][12]], m[Sigma[n][13]])
  B2B_G(v, 3, 4,  9, 14, m[Sigma[n][14]], m[Sigma[n][15]])

proc blake2Transform(ctx: var Blake2bContext, input: openArray[byte], last: bool, rounds: uint32) {.inline.} =
  var v: array[16, uint64]
  var m: array[16, uint64]

  v[0] = ctx.h[0]; v[1] = ctx.h[1]
  v[2] = ctx.h[2]; v[3] = ctx.h[3]
  v[4] = ctx.h[4]; v[5] = ctx.h[5]
  v[6] = ctx.h[6]; v[7] = ctx.h[7]
  v[8] = B2BIV[0]; v[9] = B2BIV[1]
  v[10] = B2BIV[2]; v[11] = B2BIV[3]
  v[12] = B2BIV[4]; v[13] = B2BIV[5]
  v[14] = B2BIV[6]; v[15] = B2BIV[7]

  v[12] = v[12] xor ctx.t[0]
  v[13] = v[13] xor ctx.t[1]
  if last:
    v[14] = not(v[14])

  m[0] = leLoad64(input, 0); m[1] = leLoad64(input, 8)
  m[2] = leLoad64(input, 16); m[3] = leLoad64(input, 24)
  m[4] = leLoad64(input, 32); m[5] = leLoad64(input, 40)
  m[6] = leLoad64(input, 48); m[7] = leLoad64(input, 56)
  m[8] = leLoad64(input, 64); m[9] = leLoad64(input, 72)
  m[10] = leLoad64(input, 80); m[11] = leLoad64(input, 88)
  m[12] = leLoad64(input, 96); m[13] = leLoad64(input, 104)
  m[14] = leLoad64(input, 112); m[15] = leLoad64(input, 120)

  for i in 0..<rounds:
    B2BROUND(v, m, i mod 10)

  ctx.h[0] = ctx.h[0] xor (v[0] xor v[0 + 8])
  ctx.h[1] = ctx.h[1] xor (v[1] xor v[1 + 8])
  ctx.h[2] = ctx.h[2] xor (v[2] xor v[2 + 8])
  ctx.h[3] = ctx.h[3] xor (v[3] xor v[3 + 8])
  ctx.h[4] = ctx.h[4] xor (v[4] xor v[4 + 8])
  ctx.h[5] = ctx.h[5] xor (v[5] xor v[5 + 8])
  ctx.h[6] = ctx.h[6] xor (v[6] xor v[6 + 8])
  ctx.h[7] = ctx.h[7] xor (v[7] xor v[7 + 8])

const
  blake2FInputLength*       = 213
  blake2FFinalBlockBytes    = byte(1)
  blake2FNonFinalBlockBytes = byte(0)

# input should exactly 213 bytes
# output needs to accomodate 64 bytes
proc blake2b_F*(input: openArray[byte], output: var openArray[byte]): bool =
  # Make sure the input is valid (correct length and final flag)
  if input.len != blake2FInputLength:
    return false

  if input[212] notin {blake2FNonFinalBlockBytes, blake2FFinalBlockBytes}:
    return false

  # Parse the input into the Blake2b call parameters
  var
    rounds = beLoad32(input, 0)
    final  = (input[212] == blake2FFinalBlockBytes)
    ctx: Blake2bContext

  ctx.h[0] = leLoad64(input, 4+0)
  ctx.h[1] = leLoad64(input, 4+8)
  ctx.h[2] = leLoad64(input, 4+16)
  ctx.h[3] = leLoad64(input, 4+24)
  ctx.h[4] = leLoad64(input, 4+32)
  ctx.h[5] = leLoad64(input, 4+40)
  ctx.h[6] = leLoad64(input, 4+48)
  ctx.h[7] = leLoad64(input, 4+56)

  ctx.t[0] = leLoad64(input, 196)
  ctx.t[1] = leLoad64(input, 204)

  # Execute the compression function, extract and return the result
  blake2Transform(ctx, input.toOpenArray(68, 195), final, rounds)

  leStore64(output, 0, ctx.h[0])
  leStore64(output, 8, ctx.h[1])
  leStore64(output, 16, ctx.h[2])
  leStore64(output, 24, ctx.h[3])
  leStore64(output, 32, ctx.h[4])
  leStore64(output, 40, ctx.h[5])
  leStore64(output, 48, ctx.h[6])
  leStore64(output, 56, ctx.h[7])
  result = true
