# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  boringssl

template getPtr(x: openArray[byte]): ptr uint8 =
  if x.len > 0:
    cast[ptr uint8](x[0].unsafeAddr)
  else:
    nil

proc modExpFallback(base, exp, modulo, res: ptr BIGNUM, ctx: ptr BN_CTX): bool =
  ## Square-and-multiply fallback mirroring BoringSSL's internal mod_exp_even.

  if BN_nnmod(base, base, modulo, ctx) != 1:
    return false

  let bits = BN_num_bits(exp).cint
  if bits == 0:
    return BN_one(res) == 1

  if BN_copy(res, base).isNil:
    return false

  for i in countdown(bits - 2, 0.cint):
    if BN_mod_sqr(res, res, modulo, ctx) != 1:
      return false
    if BN_is_bit_set(exp, i) == 1 and
       BN_mod_mul(res, res, base, modulo, ctx) != 1:
      return false

  true

proc modExpEven(base, exp, modulo, res: ptr BIGNUM, ctx: ptr BN_CTX): bool =
  ## Even-modulus modexp via a CRT split of modulo = q * 2^k with q odd:
  ##   x1  = base^exp mod q      (BoringSSL Montgomery path)
  ##   x2  = base^exp mod 2^k    (truncated square-and-multiply)
  ##   res = x1 + q * ((x2 - x1) * q^-1 mod 2^k)   (Garner recombination)
  ## BoringSSL's own even-modulus handling is a schoolbook square-and-multiply
  ## with a division-based reduction per step, several times slower than this.
  ##
  ## Expects exp > 0 and modulo even, > 1 (caller handles the special cases).
  ## May clobber `base`.
  BN_CTX_start(ctx)
  defer: BN_CTX_end(ctx)

  let
    q = BN_CTX_get(ctx)
    twoK = BN_CTX_get(ctx)
    x2 = BN_CTX_get(ctx)
    t = BN_CTX_get(ctx)
    baseRed = BN_CTX_get(ctx)
    eRed = BN_CTX_get(ctx)
  if eRed.isNil: # BN_CTX_get returns nil for every call after the first failure
    return false

  let k = BN_count_low_zero_bits(modulo)
  if BN_rshift(q, modulo, k) != 1:
    return false
  if BN_set_bit(twoK, k) != 1: # twoK = 2^k
    return false

  # x2 = base^exp mod 2^k, exploiting the structure of the group (Z/2^k)*:
  # for odd base the multiplicative order divides 2^(k-2) (2 for k == 2,
  # 1 for k == 1), so only the low k-2 bits of the exponent matter. For even
  # nonzero base the result is 0 whenever exp >= k, as base^exp then contains
  # at least k factors of two. Either way the loop below runs O(k) iterations
  # on k-bit numbers regardless of the exponent size.
  if BN_copy(baseRed, base).isNil:
    return false
  if BN_mask_bits(baseRed, k) != 1:
    return false

  var
    eEff = exp
    x2Done = false
  if BN_is_zero(baseRed) == 1:
    BN_zero(x2)
    x2Done = true
  elif BN_is_odd(baseRed) == 1:
    if BN_copy(eRed, exp).isNil:
      return false
    let ordBits = if k <= 1: 0.cint elif k == 2: 1.cint else: k - 2
    if BN_mask_bits(eRed, ordBits) != 1:
      return false
    eEff = eRed
  elif BN_cmp_word(exp, k.BN_ULONG) >= 0:
    BN_zero(x2)
    x2Done = true

  if not x2Done:
    if BN_one(x2) != 1:
      return false
    for i in countdown(BN_num_bits(eEff).cint - 1, 0.cint):
      if BN_sqr(x2, x2, ctx) != 1:
        return false
      if BN_mask_bits(x2, k) != 1:
        return false
      if BN_is_bit_set(eEff, i) == 1:
        if BN_mul(x2, x2, baseRed, ctx) != 1:
          return false
        if BN_mask_bits(x2, k) != 1:
          return false

  # x1 = base^exp mod q, computed into res
  if BN_is_one(q) == 1:
    BN_zero(res) # modulo is a power of two
  elif BN_mod_exp(res, base, exp, q, ctx) != 1:
    # q wider than 16384 bits (BN_MONTGOMERY_MAX_WORDS), see modExp below
    if not modExpFallback(base, exp, q, res, ctx):
      return false

  # Garner: res = x1 + q * ((x2 - x1) * q^-1 mod 2^k)
  if BN_mod_inverse(t, q, twoK, ctx).isNil:
    return false
  if BN_mod_sub(x2, x2, res, twoK, ctx) != 1:
    return false
  if BN_mod_mul(t, t, x2, twoK, ctx) != 1:
    return false
  if BN_mul(t, q, t, ctx) != 1:
    return false
  BN_add(res, res, t) == 1

proc modExp*(b, e, m: openArray[byte]): seq[byte] =
  if m.len == 0:
    return @[0.byte]

  let
    ctx = BN_CTX_new()
    base = BN_bin2bn(b.getPtr, b.len.csize_t, nil)
    exp = BN_bin2bn(e.getPtr, e.len.csize_t, nil)
    modulo = BN_bin2bn(m.getPtr, m.len.csize_t, nil)
    res = BN_new()

  defer:
    BN_free(res)
    BN_free(modulo)
    BN_free(exp)
    BN_free(base)
    BN_CTX_free(ctx)

  if ctx.isNil or base.isNil or exp.isNil or modulo.isNil or res.isNil:
    return

  if BN_is_zero(modulo) == 1 or BN_is_one(modulo) == 1:
    # EVM special case 1
    # If m == 0: EVM returns 0.
    # If m == 1: we can shortcut that to 0 as well
    return @[0.byte]

  if BN_is_zero(exp) == 1:
    # EVM special case 2
    # If 0^0: EVM returns 1
    # For all x != 0, x^0 == 1 as well
    return @[1.byte]

  if BN_is_odd(modulo) == 1:
    if BN_mod_exp(res, base, exp, modulo, ctx) != 1:
      # BN_mod_exp rejects odd moduli wider than 16384 bits (BN_MONTGOMERY_MAX_WORDS),
      # but pre-Osaka modexp has no operand length cap, so in this case we compute
      # using the fallback square and multiply algorithm.
      if not modExpFallback(base, exp, modulo, res, ctx):
        return
  else:
    if not modExpEven(base, exp, modulo, res, ctx):
      return

  let size = BN_num_bytes(res)
  if size > 0:
    result = newSeq[byte](size.int)
    discard BN_bn2bin(res, result[0].addr)
