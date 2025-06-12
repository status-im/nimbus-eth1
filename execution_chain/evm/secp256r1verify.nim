# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  libp2p/crypto/ecnist,
  bearssl/[ec, hash]

proc verifyRaw*[T: byte | char](
    sig: EcSignature, message: openArray[T], pubkey: ecnist.EcPublicKey
): bool {.inline.} =
  ## Verify ECDSA signature ``sig`` using public key ``pubkey`` and data
  ## ``message``.
  ##
  ## Return ``true`` if message verification succeeded, ``false`` if
  ## verification failed.
  doAssert((not isNil(sig)) and (not isNil(pubkey)))
  var hc: HashCompatContext
  var hash: array[32, byte]
  var impl = ecGetDefault()
  if pubkey.key.curve in EcSupportedCurvesCint:
    let res = ecdsaI31VrfyRaw(
      impl,
      addr message[0],
      uint(len(message)),
      unsafeAddr pubkey.key,
      addr sig.buffer[0],
      uint(len(sig.buffer)),
    )
    # Clear context with initial value
    result = (res == 1)