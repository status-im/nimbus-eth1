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

proc invModPow2(res, q: ptr BIGNUM, k: cint, u, f: ptr BIGNUM,
                ctx: ptr BN_CTX): bool =
  ## res = q^-1 mod 2^k for odd q, via Hensel (Newton) lifting:
  ## x -> x * (2 - q*x) doubles the number of correct low bits each round,
  ## so only multiplications and bit masks are needed. BoringSSL's
  ## BN_mod_inverse takes its generic even-modulus path for a 2^k modulus,
  ## which has a ~5us floor and grows quadratically (1.6ms at k = 2047).
  ## `u` and `f` are caller-provided scratch variables.
  if BN_one(res) != 1: # q^-1 mod 2 = 1 for odd q
    return false
  var bits = 1.cint
  while bits < k:
    bits = min(bits * 2, k)
    # u = q * res mod 2^bits (correct to bits/2 low bits, i.e. u = 1 + d
    # with d = 0 mod 2^(bits/2))
    if BN_copy(u, q).isNil:
      return false
    if BN_mask_bits(u, bits) != 1:
      return false
    if BN_mul(u, u, res, ctx) != 1:
      return false
    if BN_mask_bits(u, bits) != 1:
      return false
    if BN_is_one(u) == 1: # converged (always the case for q = 1)
      continue
    # res = res * (2 - u) mod 2^bits, with 2 - u computed as the
    # non-negative 2^bits + 2 - u (0 < u < 2^bits)
    BN_zero(f)
    if BN_set_bit(f, bits) != 1:
      return false
    if BN_add_word(f, 2) != 1:
      return false
    if BN_sub(f, f, u) != 1:
      return false
    if BN_mul(res, res, f, ctx) != 1:
      return false
    if BN_mask_bits(res, bits) != 1:
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
  # baseRed and eRed are no longer needed and are reused as scratch space
  if not invModPow2(t, q, k, baseRed, eRed, ctx):
    return false
  if BN_mod_sub(x2, x2, res, twoK, ctx) != 1:
    return false
  if BN_mod_mul(t, t, x2, twoK, ctx) != 1:
    return false
  if BN_mul(t, q, t, ctx) != 1:
    return false
  BN_add(res, res, t) == 1

proc modExpOdd(base, exp, modulo, res: ptr BIGNUM, ctx: ptr BN_CTX): bool =
  ## Odd-modulus exponentiation. The precompile's modulus is public, so we build
  ## the Montgomery context with the variable-time BN_MONT_CTX_new_for_modulus
  ## instead of letting BN_mod_exp use its constant-time setup - that setup only
  ## exists to hide private-key moduli and is markedly slower, ~25% of a small-
  ## exponent (e.g. RSA e=65537) call. Falls back to square-and-multiply when
  ## Montgomery setup is unavailable, e.g. moduli beyond BN_MONTGOMERY_MAX_WORDS.
  let mont = BN_MONT_CTX_new_for_modulus(modulo, ctx)
  if mont.isNil:
    return modExpFallback(base, exp, modulo, res, ctx)
  defer: BN_MONT_CTX_free(mont)
  # BN_mod_exp_mont requires 0 <= base < modulo.
  if BN_ucmp(base, modulo) >= 0 and BN_nnmod(base, base, modulo, ctx) != 1:
    return false
  if BN_mod_exp_mont(res, base, exp, modulo, ctx, mont) == 1:
    return true
  modExpFallback(base, exp, modulo, res, ctx)

# A per-thread BN_CTX reused across calls. Allocating a fresh context plus four
# heap BIGNUMs per call dominates the cost of small modexp inputs (~0.9us of the
# ~0.9us a 1-byte call takes). Pooling the operands via BN_CTX_get - and letting
# BN_mod_exp draw its own internal scratch (Montgomery ctx, window table) from
# the same warm pool - roughly halves per-call overhead and cuts even the small
# compute cases by ~30%. Thread-local so parallel block execution stays safe
# (each worker gets its own ctx); the ctx leaks at thread exit, matching the
# thread-local-context pattern already used by nim-secp256k1.
var modExpCtx {.threadvar.}: ptr BN_CTX

proc getModExpCtx(): ptr BN_CTX =
  ## This thread's reusable BN_CTX, created on first use. Mutating a thread-local
  ## cache is not an observable side effect (same reasoning as nim-secp256k1's
  ## getContext), so we hide it to keep the precompile's `func` callers pure.
  {.cast(noSideEffect).}:
    if modExpCtx.isNil:
      modExpCtx = BN_CTX_new()
    modExpCtx

proc modExp*(b, e, m: openArray[byte]): seq[byte] =
  if m.len == 0:
    return @[0.byte]

  let ctx = getModExpCtx()
  if ctx.isNil:
    return

  BN_CTX_start(ctx)
  defer: BN_CTX_end(ctx)

  let
    base = BN_CTX_get(ctx)
    exp = BN_CTX_get(ctx)
    modulo = BN_CTX_get(ctx)
    res = BN_CTX_get(ctx)
  # A pool-growth failure makes this and every prior get return nil, so testing
  # the last one suffices.
  if res.isNil:
    return

  # BN_CTX_get returns freshly zeroed BIGNUMs, so empty inputs need no import.
  if b.len > 0 and BN_bin2bn(b.getPtr, b.len.csize_t, base).isNil: return
  if e.len > 0 and BN_bin2bn(e.getPtr, e.len.csize_t, exp).isNil: return
  if m.len > 0 and BN_bin2bn(m.getPtr, m.len.csize_t, modulo).isNil: return

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

  # For even moduli with very short exponents the CRT split in modExpEven
  # loses: BoringSSL's schoolbook even-modulus loop is only a handful of
  # multiplications there, cheaper than the split's fixed Montgomery setup.
  const evenExpBitsCutoff = 8

  if BN_is_odd(modulo) == 1:
    if not modExpOdd(base, exp, modulo, res, ctx):
      return
  elif BN_num_bits(exp) <= evenExpBitsCutoff:
    # Even modulus with a tiny exponent: BN_mod_exp's schoolbook even path is
    # cheaper than modExpEven's CRT split here. (BN_mod_exp handles even moduli;
    # it also transparently falls to its own square-and-multiply for very wide
    # moduli.)
    if BN_mod_exp(res, base, exp, modulo, ctx) != 1:
      if not modExpFallback(base, exp, modulo, res, ctx):
        return
  else:
    if not modExpEven(base, exp, modulo, res, ctx):
      return

  let size = BN_num_bytes(res)
  if size > 0:
    result = newSeq[byte](size.int)
    discard BN_bn2bin(res, result[0].addr)
