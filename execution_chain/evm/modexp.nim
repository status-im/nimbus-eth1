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

  if BN_mod_exp(res, base, exp, modulo, ctx) != 1:
    # BN_mod_exp rejects odd moduli wider than 16384 bits (BN_MONTGOMERY_MAX_WORDS),
    # but pre-Osaka modexp has no operand length cap, so in this case we compute
    # using the fallback square and multiply algorithm.
    if not modExpFallback(base, exp, modulo, res, ctx):
      return

  let size = BN_num_bytes(res)
  if size > 0:
    result = newSeq[byte](size.int)
    discard BN_bn2bin(res, result[0].addr)
