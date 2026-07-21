# Nimbus
# Copyright (c) 2020-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import nimcrypto/utils

# Blake2 `F` compression function with the variable `rounds` parameter
# required by EIP-152, implemented in blake2/blake2b_f.c on top of the
# official BLAKE2 SSE source (the headers in blake2/ are unmodified upstream
# copies). On non-x86 targets the C file falls back to the portable
# reference implementation.

const
  blake2FInputLength*       = 213
  blake2FFinalBlockBytes    = byte(1)
  blake2FNonFinalBlockBytes = byte(0)

{.compile: "blake2/blake2b_f.c".}

proc nimbusBlake2bF(rounds: uint32, h: ptr uint64, blck: ptr byte,
                    t: ptr uint64, last: cint)
                   {.importc: "nimbus_blake2b_f", cdecl.}

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
    h: array[8, uint64]
    t: array[2, uint64]
    m: array[128, byte]

  let
    rounds = beLoad32(input, 0)
    last   = cint(input[212] == blake2FFinalBlockBytes)

  h[0] = leLoad64(input, 4+0)
  h[1] = leLoad64(input, 4+8)
  h[2] = leLoad64(input, 4+16)
  h[3] = leLoad64(input, 4+24)
  h[4] = leLoad64(input, 4+32)
  h[5] = leLoad64(input, 4+40)
  h[6] = leLoad64(input, 4+48)
  h[7] = leLoad64(input, 4+56)

  t[0] = leLoad64(input, 196)
  t[1] = leLoad64(input, 204)

  copyMem(addr m[0], unsafeAddr input[68], 128)

  # Execute the compression function, extract and return the result
  nimbusBlake2bF(rounds, addr h[0], addr m[0], addr t[0], last)

  leStore64(output, 0, h[0])
  leStore64(output, 8, h[1])
  leStore64(output, 16, h[2])
  leStore64(output, 24, h[3])
  leStore64(output, 32, h[4])
  leStore64(output, 40, h[5])
  leStore64(output, 48, h[6])
  leStore64(output, 56, h[7])
  result = true
