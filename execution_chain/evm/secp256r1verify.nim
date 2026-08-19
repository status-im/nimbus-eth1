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
