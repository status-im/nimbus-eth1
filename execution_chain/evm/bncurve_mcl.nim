# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  results,
  stew/assign2,
  mcl/bn_mini,
  ./evm_errors,
  ./types

func bn256ecAddImpl*(c: Computation): EvmResultVoid  =
  var
    input: array[128, byte]
    p1 {.noinit.}: BnG1
    p2 {.noinit.}: BnG1
    apo {.noinit.}: BnG1

  # Padding data
  let len = min(c.msg.data.len, 128) - 1
  assign(input.toOpenArray(0, len), c.msg.data.toOpenArray(0, len))

  if not p1.fromBytesBE(input[0].addr):
    return err(prcErr(PrcInvalidPoint))

  if not p2.fromBytesBE(input[64].addr):
    return err(prcErr(PrcInvalidPoint))

  apo.add(p1, p2)

  c.output.setLen(64)
  if not apo.toBytesBE(c.output[0].addr):
    zeroMem(c.output[0].addr, 64)

  ok()

func bn256ecMulImpl*(c: Computation): EvmResultVoid  =
  var
    input: array[96, byte]
    p1 {.noinit.}: BnG1
    fr {.noinit.}: BnFr
    apo {.noinit.}: BnG1

  # Padding data
  let len = min(c.msg.data.len, 96) - 1
  assign(input.toOpenArray(0, len), c.msg.data.toOpenArray(0, len))

  if not p1.fromBytesBE(input[0].addr):
    return err(prcErr(PrcInvalidPoint))

  if not fr.fromBytesBE(input[64].addr):
    return err(prcErr(PrcInvalidPoint))

  apo.mul(p1, fr)

  c.output.setLen(64)
  if not apo.toBytesBE(c.output[0].addr):
    zeroMem(c.output[0].addr, 64)

  ok()

func bn256ecPairingImpl*(c: Computation): EvmResultVoid  =
  let msglen = c.msg.data.len
  if msglen == 0:
    c.output.setLen(32)
    c.output[31] = 1
  else:
    # Calculate number of pairing pairs
    let count = msglen div 192
    # Pairing accumulator
    var
      acc {.noinit.}: BnFp12
      tmp {.noinit.}: BnFp12

    acc.setOne()

    var
      p1 {.noinit.}: BnG1
      p2 {.noinit.}: BnG2

    for i in 0..<count:
      let s = i * 192

      # Loading AffinePoint[G1], bytes from [0..63]
      if not p1.fromBytesBE(c.msg.data[s].addr):
        return err(prcErr(PrcInvalidPoint))

      # Loading AffinePoint[G2], bytes from [64..191]
      if not p2.fromBytesBE(c.msg.data[s+64].addr):
        return err(prcErr(PrcInvalidPoint))

      # Accumulate pairing result
      tmp.pairing(p1, p2)
      acc.mul(acc, tmp)

    c.output.setLen(32)
    if acc.isOne:
      c.output[31] = 1

  ok()
