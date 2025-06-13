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

proc `-`(x: uint32): uint32 {.inline.} =
  result = (0xFFFF_FFFF'u32 - x) + 1'u32

proc GT(x, y: uint32): uint32 {.inline.} =
  var z = cast[uint32](y - x)
  result = (z xor ((x xor y) and (x xor z))) shr 31

proc CMP(x, y: uint32): int32 {.inline.} =
  cast[int32](GT(x, y)) or -(cast[int32](GT(y, x)))

proc EQ0(x: int32): uint32 {.inline.} =
  var q = cast[uint32](x)
  result = not (q or -q) shr 31

proc NEQ(x, y: uint32): uint32 {.inline.} =
  var q = cast[uint32](x xor y)
  result = ((q or -q) shr 31)

proc LT0(x: int32): uint32 {.inline.} =
  result = cast[uint32](x) shr 31

proc checkScalar*(scalar: openArray[byte], curve: cint): uint32 =
  ## Return ``1`` if all of the following hold:
  ##   - len(``scalar``) <= ``orderlen``
  ##   - ``scalar`` != 0
  ##   - ``scalar`` is lower than the curve ``order``.
  ##
  ## Otherwise, return ``0``.
  var impl = ecGetDefault()
  var orderlen: uint = 0
  var order = cast[ptr UncheckedArray[byte]](impl.order(curve, orderlen))

  var z = 0'u32
  var c = 0'i32
  for u in scalar:
    z = z or u
  if len(scalar) == int(orderlen):
    for i in 0 ..< len(scalar):
      c = c or (-(cast[int32](EQ0(c))) and CMP(scalar[i], order[i]))
  else:
    c = -1
  result = NEQ(z, 0'u32) and LT0(c)

proc isInfinityByte*(data: openArray[byte]): bool =
  ## Check if all values in ``data`` are zero.
  for b in data:
    if b != 0:
      return false
  return true

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