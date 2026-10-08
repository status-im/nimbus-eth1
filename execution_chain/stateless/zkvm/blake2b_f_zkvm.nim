# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## BLAKE2f on the zkVM's accelerator, for guest builds only.
## Same interface as `evm/blake2b_f`

{.push raises: [], gcsafe.}

import nimcrypto/utils, stew/assign2, ./zkvm_accelerators

const blake2FInputLength* = 213

func blake2b_F*(input: openArray[byte], output: var openArray[byte]): bool =
  ## `input` is the precompile's 213 bytes, `output` receives the 64-byte state.
  if input.len != blake2FInputLength or output.len < 64:
    return false

  if input[212] > 1'u8:
    return false

  assign(output.toOpenArray(0, 63), input.toOpenArray(4, 67))
  blake2fCompress(
    beLoad32(input, 0),
    output.toOpenArray(0, 63),
    input.toOpenArray(68, 195),
    input.toOpenArray(196, 211),
    input[212] == 1'u8,
  )
