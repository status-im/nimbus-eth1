# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

## BN254 precompile backend on the zkVM's accelerators, for guest builds only.
##
## The vendor validates the points itself and reports a bad one with the status
## a broken accelerator would use, so the wrappers return `false` for both and
## that becomes `PrcInvalidPoint` here.

{.push raises: [].}

import results, stew/assign2, ../../evm/[evm_errors, types], ./zkvm_accelerators

template padded(c: Computation, input: var openArray[byte]) =
  ## Short calldata is zero-padded to the precompile's input size.
  let n = min(c.msg.data.len, input.len)
  if n > 0:
    assign(input.toOpenArray(0, n - 1), c.msg.data.toOpenArray(0, n - 1))

func bn256ecAddImpl*(c: Computation): EvmResultVoid =
  # `(0, 0)` is the point at infinity, so an empty input is infinity + infinity.
  var input: array[128, byte]
  c.padded(input)

  var res: array[64, byte]
  if not bn254G1Add(input.toOpenArray(0, 63), input.toOpenArray(64, 127), res):
    return err(prcErr(PrcInvalidPoint))

  assign(c.output, res)

  ok()

func bn256ecMulImpl*(c: Computation): EvmResultVoid =
  var input: array[96, byte]
  c.padded(input)

  var res: array[64, byte]
  if not bn254G1Mul(input.toOpenArray(0, 63), input.toOpenArray(64, 95), res):
    return err(prcErr(PrcInvalidPoint))

  assign(c.output, res)

  ok()

func bn256ecPairingImpl*(c: Computation): EvmResultVoid =
  # The caller has already rejected a length that is not a multiple of 192. An
  # empty input pairs nothing, and the empty product is one.
  var verified = true
  if c.msg.data.len > 0 and not bn254Pairing(c.msg.data, verified):
    return err(prcErr(PrcInvalidPoint))

  c.output.setLen(32)
  if verified:
    c.output[31] = 1

  ok()
