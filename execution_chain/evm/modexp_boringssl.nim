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

template bnAssert(call: untyped) =
  ## `call` is a BoringSSL BN_* op that returns 1 on success
  doAssert call == 1

proc modExpSquareAndMultiply(base, exp, modulo, res: ptr BIGNUM, ctx: ptr BN_CTX) =
  ## The standard square and multiple algorithm
  bnAssert BN_nnmod(base, base, modulo, ctx)

  let bits = BN_num_bits(exp).cint
  if bits == 0:
    bnAssert BN_one(res)
    return

  doAssert not BN_copy(res, base).isNil

  for i in countdown(bits - 2, 0.cint):
    bnAssert BN_mod_sqr(res, res, modulo, ctx)
    if BN_is_bit_set(exp, i) == 1:
      bnAssert BN_mod_mul(res, res, base, modulo, ctx)

proc invModPow2(res, q: ptr BIGNUM, k: cint, u, f: ptr BIGNUM,
                ctx: ptr BN_CTX) =
  ## res = q^-1 mod 2^k for odd q, via Hensel (Newton) lifting:
  ## x -> x * (2 - q*x) doubles the number of correct low bits each round,
  ## so only multiplications and bit masks are needed. This is faster
  ## than BoringSSL's BN_mod_inverse for odd q with mod 2^k.
  ## `u` and `f` are caller-provided scratch variables.
  bnAssert BN_one(res) # q^-1 mod 2 = 1 for odd q
  var bits = 1.cint

  while bits < k:
    bits = min(bits * 2, k)

    # u = q * res mod 2^bits (correct to bits/2 low bits, i.e. u = 1 + d
    # with d = 0 mod 2^(bits/2))
    doAssert not BN_copy(u, q).isNil
    bnAssert BN_mask_bits(u, bits)
    bnAssert BN_mul(u, u, res, ctx)
    bnAssert BN_mask_bits(u, bits)
    if BN_is_one(u) == 1: # converged (always the case for q = 1)
      continue

    # res = res * (2 - u) mod 2^bits, with 2 - u computed as the
    # non-negative 2^bits + 2 - u (0 < u < 2^bits)
    BN_zero(f)
    bnAssert BN_set_bit(f, bits)
    bnAssert BN_add_word(f, 2)
    bnAssert BN_sub(f, f, u)
    bnAssert BN_mul(res, res, f, ctx)
    bnAssert BN_mask_bits(res, bits)

proc modExpOdd(base, exp, modulo, res: ptr BIGNUM, ctx: ptr BN_CTX) =
  ## Odd-modulus exponentiation. The precompile's modulus is public, so we build
  ## the Montgomery context with the variable-time BN_MONT_CTX_new_for_modulus
  ## instead of letting BN_mod_exp use its constant-time setup.
  let mont = BN_MONT_CTX_new_for_modulus(modulo, ctx)
  if mont.isNil:
    # nil for moduli beyond BN_MONTGOMERY_MAX_WORDS - a valid large input,
    # so fall back to square and multiply.
    modExpSquareAndMultiply(base, exp, modulo, res, ctx)
    return
  defer: BN_MONT_CTX_free(mont)

  # BN_mod_exp_mont requires 0 <= base < modulo.
  if BN_ucmp(base, modulo) >= 0:
    bnAssert BN_nnmod(base, base, modulo, ctx)
  if BN_mod_exp_mont(res, base, exp, modulo, ctx, mont) != 1:
    # same large modulus rejection as above is possible here
    modExpSquareAndMultiply(base, exp, modulo, res, ctx)

proc modExpEven(base, exp, modulo, res: ptr BIGNUM, ctx: ptr BN_CTX) =
  ## Even-modulus modexp via a CRT split of modulo = q * 2^k with q odd:
  ##   x1  = base^exp mod q      (BoringSSL Montgomery path)
  ##   x2  = base^exp mod 2^k    (truncated square-and-multiply)
  ##   res = x1 + q * ((x2 - x1) * q^-1 mod 2^k)   (Garner recombination)
  ## BoringSSL's own even-modulus handling is several times slower than this.
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
  doAssert not eRed.isNil # nil propagates from the first failed get (OOM)

  let k = BN_count_low_zero_bits(modulo)
  bnAssert BN_rshift(q, modulo, k)
  bnAssert BN_set_bit(twoK, k) # twoK = 2^k

  # x2 = base^exp mod 2^k, exploiting the structure of the group (Z/2^k)*:
  # for odd base the multiplicative order divides 2^(k-2) (2 for k == 2,
  # 1 for k == 1), so only the low k-2 bits of the exponent matter. For even
  # nonzero base the result is 0 whenever exp >= k, as base^exp then contains
  # at least k factors of two. Either way the loop below runs O(k) iterations
  # on k-bit numbers regardless of the exponent size.
  doAssert not BN_copy(baseRed, base).isNil
  bnAssert BN_mask_bits(baseRed, k)

  var
    eEff = exp
    x2Done = false
  if BN_is_zero(baseRed) == 1:
    BN_zero(x2)
    x2Done = true
  elif BN_is_odd(baseRed) == 1:
    doAssert not BN_copy(eRed, exp).isNil
    let ordBits = if k <= 1: 0.cint elif k == 2: 1.cint else: k - 2
    bnAssert BN_mask_bits(eRed, ordBits)
    eEff = eRed
  elif BN_cmp_word(exp, k.BN_ULONG) >= 0:
    BN_zero(x2)
    x2Done = true

  if not x2Done:
    # Compute x2 using square and multiply but with the modular reduction
    # replaced by a cheap bit mask because the modulus is 2^k
    bnAssert BN_one(x2)
    for i in countdown(BN_num_bits(eEff).cint - 1, 0.cint):
      bnAssert BN_sqr(x2, x2, ctx)
      bnAssert BN_mask_bits(x2, k)
      if BN_is_bit_set(eEff, i) == 1:
        bnAssert BN_mul(x2, x2, baseRed, ctx)
        bnAssert BN_mask_bits(x2, k)

  # x1 = base^exp mod q, computed into res (vartime Montgomery setup, with the
  # square-and-multiply fallback for q wider than BN_MONTGOMERY_MAX_WORDS)
  if BN_is_one(q) == 1:
    BN_zero(res) # modulo is a power of two
  else:
    modExpOdd(base, exp, q, res, ctx)

  # Garner: res = x1 + q * ((x2 - x1) * q^-1 mod 2^k)
  # baseRed and eRed are no longer needed and are reused as scratch space
  invModPow2(t, q, k, baseRed, eRed, ctx)
  bnAssert BN_mod_sub(x2, x2, res, twoK, ctx)
  bnAssert BN_mod_mul(t, t, x2, twoK, ctx)
  bnAssert BN_mul(t, q, t, ctx)
  bnAssert BN_add(res, res, t)

var modExpCtx {.threadvar.}: ptr BN_CTX

proc getModExpCtx(): ptr BN_CTX =
  {.cast(noSideEffect).}:
    if modExpCtx.isNil:
      modExpCtx = BN_CTX_new()
    modExpCtx

proc modExpInto*(b, e, m: openArray[byte], output: var openArray[byte]) =
  if output.len == 0:
    return

  let ctx = getModExpCtx()
  doAssert not ctx.isNil

  BN_CTX_start(ctx)
  defer: BN_CTX_end(ctx)

  let
    base = BN_CTX_get(ctx)
    exp = BN_CTX_get(ctx)
    modulo = BN_CTX_get(ctx)
    res = BN_CTX_get(ctx)
  doAssert not res.isNil # nil propagates from the first failed get

  # BN_CTX_get returns freshly zeroed BIGNUMs, so empty inputs need no import.
  if b.len > 0: doAssert not BN_bin2bn(b.getPtr, b.len.csize_t, base).isNil
  if e.len > 0: doAssert not BN_bin2bn(e.getPtr, e.len.csize_t, exp).isNil
  doAssert not BN_bin2bn(m.getPtr, m.len.csize_t, modulo).isNil

  # For even moduli with very short exponents the CRT split in modExpEven
  # is slower than the square and multiply algorithm.
  const evenExpBitsCutoff = 8

  if BN_is_zero(modulo) == 1 or BN_is_one(modulo) == 1:
    # m == 0 or m == 1: EVM result is 0; res is already zero from BN_CTX_get.
    discard
  elif BN_is_zero(exp) == 1:
    # x^0 == 1, and 0^0 == 1 per EVM.
    bnAssert BN_one(res)
  elif BN_is_odd(modulo) == 1:
    modExpOdd(base, exp, modulo, res, ctx)
  elif BN_num_bits(exp) <= evenExpBitsCutoff:
    # Even modulus, tiny exponent: BN_mod_exp's even path which uses square
    # and multiply beats modExpEven's CRT split here. Unlike its odd path,
    # BN_mod_exp's even path (mod_exp_even) has no width limit, so it only
    # fails on allocation failure.
    bnAssert BN_mod_exp(res, base, exp, modulo, ctx)
  else:
    modExpEven(base, exp, modulo, res, ctx)

  # res is reduced mod m, so it always fits left-padded into output.len bytes.
  bnAssert BN_bn2bin_padded(cast[ptr uint8](output[0].addr), output.len.csize_t, res)

proc modExp*(b, e, m: openArray[byte]): seq[byte] =
  if m.len == 0:
    return
  result = newSeq[byte](m.len)
  modExpInto(b, e, m, result)
