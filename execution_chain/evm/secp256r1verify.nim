# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import ../compile_info

when enable_boringssl:
  import boringssl

  proc verifyRaw*(
      sig: openArray[byte], hash: openArray[byte], pubkey: openArray[byte]
  ): bool =
    if sig.len != 64 or hash.len != 32 or pubkey.len != 64:
      return false

    let key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1)
    if key.isNil:
      return false
    defer:
      EC_KEY_free(key)

    let
      x = BN_bin2bn(pubkey[0].addr, 32, nil)
      y = BN_bin2bn(pubkey[32].addr, 32, nil)
    defer:
      BN_free(x)
      BN_free(y)

    if x.isNil or y.isNil:
      return false

    if EC_KEY_set_public_key_affine_coordinates(key, x, y) != 1:
      return false

    ECDSA_verify_p1363(
      hash[0].addr, csize_t(hash.len), sig[0].addr, csize_t(sig.len), key) == 1

else:
  import
    bearssl/secp256r1_verify as ec,
    stew/assign2,
    stint

  const
    # The secp256r1 field prime.
    FieldPrime =
      UInt256.fromHex("0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff")

  func isInfinityByte(data: openArray[byte]): bool =
    ## True when every byte is zero, i.e. the encoded point at infinity.
    for b in data:
      if b != 0:
        return false
    true

  func checkPublicKey(key: openArray[byte]): bool =
    ## On-curve check: BearSSL has no dedicated predicate, so multiply by a small
    ## scalar and let it report failure for a point off the curve.
    let
      x = [byte 0x00, 0x01]
      impl = ecGetDefault()
    impl.mul(key[0].addr, key.len.uint, x[0].addr, x.len.uint, EC_secp256r1) != 0

  proc verifyRaw*(
      sig: openArray[byte], hash: openArray[byte], pubkey: openArray[byte]
  ): bool =
    if sig.len != 64 or hash.len != 32 or pubkey.len != 64:
      return false

    if pubkey.isInfinityByte:
      return false

    let
      x = UInt256.fromBytesBE(pubkey.toOpenArray(0, 31))
      y = UInt256.fromBytesBE(pubkey.toOpenArray(32, 63))
    if x >= FieldPrime or y >= FieldPrime:
      return false

    # BearSSL wants the uncompressed SEC1 encoding: 0x04 || X || Y. Both are
    # written in full below, so neither needs zero-initialising first.
    var buf {.noinit.}: array[65, byte]
    buf[0] = 4.byte
    assign(buf.toOpenArray(1, 64), pubkey)

    if not checkPublicKey(buf):
      return false

    var pk {.noinit.}: ec.EcPublicKey
    pk.curve = EC_secp256r1
    pk.q = buf[0].addr
    pk.qlen = 65

    secp256r1_i31_vrfy_raw(
      hash[0].addr, hash.len.uint, pk.addr, sig[0].addr, sig.len.uint) == 1
