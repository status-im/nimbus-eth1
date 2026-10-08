# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

## BLS12-381 precompile backend on the zkVM's accelerators, for guest builds
## only. Same interface as `evm/blscurve_nim`.
##
## EIP-2537 carries every field element right-aligned in 64 bytes, the
## accelerators take the 48 bytes alone. Stripping that padding is done here
## and so is rejecting a non-zero pad.

{.push raises: [].}

import results, stew/assign2, ../../evm/[evm_errors, types], ./zkvm_accelerators

const
  FpBytes = 48
  PadBytes = 16 ## zero bytes ahead of each field element in the EVM encoding

func unpad(dst: var openArray[byte], src: openArray[byte]): bool =
  ## One field element, 64 padded bytes in, 48 out.
  for i in 0 ..< PadBytes:
    if src[i] != 0.byte:
      return false

  assign(dst, src.toOpenArray(PadBytes, PadBytes + FpBytes - 1))
  true

func unpadG1(dst: var openArray[byte], src: openArray[byte]): bool =
  ## A G1 point: 128 padded bytes in, 96 out.
  unpad(dst.toOpenArray(0, 47), src.toOpenArray(0, 63)) and
    unpad(dst.toOpenArray(48, 95), src.toOpenArray(64, 127))

func unpadG2(dst: var openArray[byte], src: openArray[byte]): bool =
  ## A G2 point: 256 padded bytes in, 192 out.
  unpad(dst.toOpenArray(0, 47), src.toOpenArray(0, 63)) and
    unpad(dst.toOpenArray(48, 95), src.toOpenArray(64, 127)) and
    unpad(dst.toOpenArray(96, 143), src.toOpenArray(128, 191)) and
    unpad(dst.toOpenArray(144, 191), src.toOpenArray(192, 255))

template padded(c: Computation, point: openArray[byte]) =
  ## The result back into the EVM encoding.
  c.output.setLen((point.len div FpBytes) * (FpBytes + PadBytes))
  for i in 0 ..< point.len div FpBytes:
    assign(
      c.output.toOpenArray(i * 64 + PadBytes, i * 64 + 63),
      point.toOpenArray(i * FpBytes, i * FpBytes + FpBytes - 1),
    )

func blsG1AddImpl*(c: Computation): EvmResultVoid =
  template input(): untyped =
    c.msg.data

  var
    a {.noinit.}: array[96, byte]
    b {.noinit.}: array[96, byte]

  if not unpadG1(a, input.toOpenArray(0, 127)):
    return err(prcErr(PrcInvalidPoint))

  if not unpadG1(b, input.toOpenArray(128, 255)):
    return err(prcErr(PrcInvalidPoint))

  var res {.noinit.}: array[96, byte]
  if not bls12G1Add(a, b, res):
    return err(prcErr(PrcInvalidPoint))

  c.padded(res)
  ok()

func blsG1MultiExpImpl*(c: Computation): EvmResultVoid =
  template input(): untyped =
    c.msg.data

  const L = 160
  let K = input.len div L

  # The zkvm accelerator's layout: point and scalar adjacent, both unpadded.
  var pairs = newSeq[byte](K * 128)

  # Decode point scalar pairs
  for i in 0 ..< K:
    let
      off = L * i
      dst = 128 * i

    # Decode G1 point
    if not unpadG1(pairs.toOpenArray(dst, dst + 95), input.toOpenArray(off, off + 127)):
      return err(prcErr(PrcInvalidPoint))

    # Decode scalar value
    assign(
      pairs.toOpenArray(dst + 96, dst + 127), input.toOpenArray(off + 128, off + 159)
    )

  var res {.noinit.}: array[96, byte]
  if not bls12G1Msm(pairs, res):
    return err(prcErr(PrcInvalidPoint))

  c.padded(res)
  ok()

func blsG2AddImpl*(c: Computation): EvmResultVoid =
  template input(): untyped =
    c.msg.data

  var
    a {.noinit.}: array[192, byte]
    b {.noinit.}: array[192, byte]

  if not unpadG2(a, input.toOpenArray(0, 255)):
    return err(prcErr(PrcInvalidPoint))

  if not unpadG2(b, input.toOpenArray(256, 511)):
    return err(prcErr(PrcInvalidPoint))

  var res {.noinit.}: array[192, byte]
  if not bls12G2Add(a, b, res):
    return err(prcErr(PrcInvalidPoint))

  c.padded(res)
  ok()

func blsG2MultiExpImpl*(c: Computation): EvmResultVoid =
  template input(): untyped =
    c.msg.data

  const L = 288
  let K = input.len div L

  var pairs = newSeq[byte](K * 224)

  # Decode point scalar pairs
  for i in 0 ..< K:
    let
      off = L * i
      dst = 224 * i

    # Decode G2 point
    if not unpadG2(pairs.toOpenArray(dst, dst + 191), input.toOpenArray(off, off + 255)):
      return err(prcErr(PrcInvalidPoint))

    # Decode scalar value
    assign(
      pairs.toOpenArray(dst + 192, dst + 223), input.toOpenArray(off + 256, off + 287)
    )

  var res {.noinit.}: array[192, byte]
  if not bls12G2Msm(pairs, res):
    return err(prcErr(PrcInvalidPoint))

  c.padded(res)
  ok()

func blsPairingImpl*(c: Computation): EvmResultVoid =
  template input(): untyped =
    c.msg.data

  const L = 384
  let K = input.len div L

  var pairs = newSeq[byte](K * 288)

  # Decode pairs
  for i in 0 ..< K:
    let
      off = L * i
      dst = 288 * i

    # Decode G1 point
    if not unpadG1(pairs.toOpenArray(dst, dst + 95), input.toOpenArray(off, off + 127)):
      return err(prcErr(PrcInvalidPoint))

    # Decode G2 point
    if not unpadG2(
      pairs.toOpenArray(dst + 96, dst + 287), input.toOpenArray(off + 128, off + 383)
    ):
      return err(prcErr(PrcInvalidPoint))

  var verified = false
  if not bls12Pairing(pairs, verified):
    return err(prcErr(PrcInvalidPoint))

  c.output.setLen(32)

  if verified:
    c.output[^1] = 1.byte
  ok()

func blsMapG1Impl*(c: Computation): EvmResultVoid =
  template input(): untyped =
    c.msg.data

  var fe {.noinit.}: array[48, byte]
  if not unpad(fe, input):
    return err(prcErr(PrcInvalidPoint))

  var res {.noinit.}: array[96, byte]
  if not bls12MapFpToG1(fe, res):
    return err(prcErr(PrcInvalidPoint))

  c.padded(res)
  ok()

func blsMapG2Impl*(c: Computation): EvmResultVoid =
  template input(): untyped =
    c.msg.data

  var fe {.noinit.}: array[96, byte]
  if not unpad(fe.toOpenArray(0, 47), input.toOpenArray(0, 63)):
    return err(prcErr(PrcInvalidPoint))

  if not unpad(fe.toOpenArray(48, 95), input.toOpenArray(64, 127)):
    return err(prcErr(PrcInvalidPoint))

  var res {.noinit.}: array[192, byte]
  if not bls12MapFp2ToG2(fe, res):
    return err(prcErr(PrcInvalidPoint))

  c.padded(res)
  ok()
