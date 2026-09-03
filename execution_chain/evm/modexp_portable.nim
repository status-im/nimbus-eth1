# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Portable modexp (EIP-198) over `stint`, used when `enable_boringssl` is off.
## Pure Nim, so it cross-compiles for a freestanding target where BoringSSL
## cannot.
##
## **Incomplete, and only intended for quick local testing.**
##
## - Handles operands up to 256 bytes; larger ones raise a Defect. EIP-7823
##   permits 1024.
## - Fails the modexp cases of the precompile test suite for that reason.
## - LLM-generated, and neither reviewed nor benchmarked.
##
## The intended backend is the `zkvm_modexp` accelerator, which has no such
## limit.

{.push raises: [].}

import stint

const MaxOperandBytes* = 256
  ## Largest base/modulus this backend handles.

func loadBE(bits: static int, src: openArray[byte]): StUint[bits] =
  ## Big-endian load, right-aligned into the full width. Built explicitly since
  ## stint documents its padding of short inputs as subject to change.
  const byteWidth = bits div 8
  var buf: array[byteWidth, byte]
  let n = min(src.len, byteWidth)
  for i in 0 ..< n:
    buf[byteWidth - n + i] = src[src.len - n + i]
  StUint[bits].fromBytesBE(buf)

func modExpImpl(
    bits: static int, b, e, m: openArray[byte], output: var openArray[byte]
) =
  ## Square-and-multiply, left to right over the exponent bits. The exponent
  ## stays raw bytes so its length does not force a wider instantiation.
  const byteWidth = bits div 8

  let modulus = loadBE(bits, m)

  # EIP-198: a zero modulus yields a zero-filled result of the modulus length.
  if modulus.isZero:
    for i in 0 ..< output.len:
      output[i] = 0
    return

  let base = loadBE(bits, b) mod modulus

  # `one mod modulus`, not `one`: gives 0 for modulus 1, and the right answer
  # when the exponent is zero and the loop never runs.
  var res = one(StUint[bits]) mod modulus

  # Skip leading zero bytes so cost tracks the exponent's magnitude, not its
  # encoded length. Leading zero bits are not skipped: squaring 1 is a no-op.
  var i = 0
  while i < e.len and e[i] == 0:
    inc i

  while i < e.len:
    let by = e[i]
    for bit in countdown(7, 0):
      res = res.mulmod(res, modulus)
      if ((by shr bit) and 1'u8) == 1'u8:
        res = res.mulmod(base, modulus)
    inc i

  # Left-pad or truncate into the caller's modulus-length buffer.
  let raw = res.toBytesBE()
  if output.len >= byteWidth:
    for k in 0 ..< output.len - byteWidth:
      output[k] = 0
    for k in 0 ..< byteWidth:
      output[output.len - byteWidth + k] = raw[k]
  else:
    # `res` is reduced mod `modulus`, so dropped bytes are always zero.
    for k in 0 ..< output.len:
      output[k] = raw[byteWidth - output.len + k]

func modExpInto*(b, e, m: openArray[byte], output: var openArray[byte]) =
  ## Compute `b^e mod m` into `output`, which must be modulus-length.
  if m.len == 0:
    return

  # The base is reduced mod `m`, so the width must hold the larger of the two.
  let need = max(b.len, m.len)

  if need <= 32:
    modExpImpl(256, b, e, m, output)
  elif need <= 64:
    modExpImpl(512, b, e, m, output)
  elif need <= 128:
    modExpImpl(1024, b, e, m, output)
  elif need <= 256:
    modExpImpl(2048, b, e, m, output)
  else:
    raiseAssert "modexp operand exceeds " & $MaxOperandBytes & " bytes"

func modExp*(b, e, m: openArray[byte]): seq[byte] =
  if m.len == 0:
    return
  result = newSeq[byte](m.len)
  modExpInto(b, e, m, result)
