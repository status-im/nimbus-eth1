# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

## BLS12-381 precompile backend on blst, EIP-2537.

{.push raises: [].}

import
  results,
  ./evm_errors,
  ./types,
  ./blscurve

func blsG1AddImpl*(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  var
    a {.noinit.}: BLS_G1
    b {.noinit.}: BLS_G1

  if not a.decodePoint(input.toOpenArray(0, 127)):
    return err(prcErr(PrcInvalidPoint))

  if not b.decodePoint(input.toOpenArray(128, 255)):
    return err(prcErr(PrcInvalidPoint))

  a.add b

  c.output.setLen(128)
  if not encodePoint(a, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsG1MultiExpImpl*(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  const L = 160
  let K = input.len div L

  var
    points = newSeq[BLS_G1P](K)
    scalars = newSeq[BLS_SCALAR](K)
    acc {.noinit.}: BLS_G1

  # Decode point scalar pairs
  for i in 0..<K:
    let off = L * i

    # Decode G1 point
    if not points[i].decodePoint(input.toOpenArray(off, off+127)):
      return err(prcErr(PrcInvalidPoint))

    if not points[i].isInf and not points[i].subgroupCheck:
      return err(prcErr(PrcInvalidPoint))

    # Decode scalar value
    if not scalars[i].fromBytes(input.toOpenArray(off+128, off+159)):
      return err(prcErr(PrcInvalidParam))

  if K == 1:
    acc.fromAffine(points[0])
    acc.mul(scalars[0])
  else:
    acc.multiExp(points, scalars)

  c.output.setLen(128)
  if not encodePoint(acc, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsG2AddImpl*(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  var
    a {.noinit.}: BLS_G2
    b {.noinit.}: BLS_G2

  if not a.decodePoint(input.toOpenArray(0, 255)):
    return err(prcErr(PrcInvalidPoint))

  if not b.decodePoint(input.toOpenArray(256, 511)):
    return err(prcErr(PrcInvalidPoint))

  a.add b

  c.output.setLen(256)
  if not encodePoint(a, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsG2MultiExpImpl*(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  const L = 288
  let K = input.len div L

  var
    points = newSeq[BLS_G2P](K)
    scalars = newSeq[BLS_SCALAR](K)
    acc {.noinit.}: BLS_G2

  # Decode point scalar pairs
  for i in 0..<K:
    let off = L * i

    # Decode G1 point
    if not points[i].decodePoint(input.toOpenArray(off, off+255)):
      return err(prcErr(PrcInvalidPoint))

    if not points[i].isInf and not points[i].subgroupCheck:
      return err(prcErr(PrcInvalidPoint))

    # Decode scalar value
    if not scalars[i].fromBytes(input.toOpenArray(off+256, off+287)):
      return err(prcErr(PrcInvalidParam))

  # Pippenger only starts paying off above two pairs in G2
  if K <= 2:
    acc.fromAffine(points[0])
    acc.mul(scalars[0])
    for i in 1..<K:
      var t {.noinit.}: BLS_G2
      t.fromAffine(points[i])
      t.mul(scalars[i])
      acc.add(t)
  else:
    acc.multiExp(points, scalars)

  c.output.setLen(256)
  if not encodePoint(acc, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsPairingImpl*(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  const L = 384
  let K = input.len div L

  var
    g1 {.noinit.}: BLS_G1P
    g2 {.noinit.}: BLS_G2P
    g1Points = newSeqOfCap[BLS_G1P](K)
    g2Points = newSeqOfCap[BLS_G2P](K)

  # Decode pairs
  for i in 0..<K:
    let off = L * i

    # Decode G1 point
    if not g1.decodePoint(input.toOpenArray(off, off+127)):
      return err(prcErr(PrcInvalidPoint))

    # Decode G2 point
    if not g2.decodePoint(input.toOpenArray(off+128, off+383)):
      return err(prcErr(PrcInvalidPoint))

    # 'point is on curve' check already done,
    # Here we need to apply subgroup checks.
    if not g1.subgroupCheck:
      return err(prcErr(PrcInvalidPoint))

    if not g2.subgroupCheck:
      return err(prcErr(PrcInvalidPoint))

    # A pair with a point at infinity pairs to the identity, leaving the
    # product unchanged. It must be skipped: millerLoopN cannot take one.
    if g1.isInf or g2.isInf:
      continue

    g1Points.add g1
    g2Points.add g2

  c.output.setLen(32)

  # An empty product is the identity, so the check succeeds.
  if g1Points.len == 0 or millerLoopN(g1Points, g2Points).check():
    c.output[^1] = 1.byte
  ok()

func blsMapG1Impl*(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  var fe {.noinit.}: BLS_FP
  if not fe.decodeFE(input):
    return err(prcErr(PrcInvalidPoint))

  let p = fe.mapFPToG1()

  c.output.setLen(128)
  if not encodePoint(p, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsMapG2Impl*(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  var fe {.noinit.}: BLS_FP2
  if not fe.decodeFE(input):
    return err(prcErr(PrcInvalidPoint))

  let p = fe.mapFPToG2()

  c.output.setLen(256)
  if not encodePoint(p, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()
