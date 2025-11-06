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
  bncurve/[fields, groups],
  ./evm_errors,
  ./types

func simpleDecode(dst: var FQ2, src: openArray[byte]): bool {.noinit.} =
  # bypassing FQ2.fromBytes
  # because we want to check `value > modulus`
  result = false
  if dst.c1.fromBytes(src.toOpenArray(0, 31)) and
     dst.c0.fromBytes(src.toOpenArray(32, 63)):
    result = true

template simpleDecode(dst: var FQ, src: openArray[byte]): bool =
  fromBytes(dst, src)

func getPoint[T: G1|G2](_: typedesc[T], data: openArray[byte]): EvmResult[Point[T]] =
  when T is G1:
    const nextOffset = 32
    var px, py: FQ
  else:
    const nextOffset = 64
    var px, py: FQ2

  if not px.simpleDecode(data.toOpenArray(0, nextOffset - 1)):
    return err(prcErr(PrcInvalidPoint))
  if not py.simpleDecode(data.toOpenArray(nextOffset, nextOffset * 2 - 1)):
    return err(prcErr(PrcInvalidPoint))

  if px.isZero() and py.isZero():
    ok(T.zero())
  else:
    var ap: AffinePoint[T]
    if not ap.init(px, py):
      return err(prcErr(PrcInvalidPoint))
    ok(ap.toJacobian())

func getFR(data: openArray[byte]): EvmResult[FR] =
  var res: FR
  if not res.fromBytes2(data):
    return err(prcErr(PrcInvalidPoint))
  ok(res)

func bn256ecAddImpl*(c: Computation): EvmResultVoid  =
  var
    input: array[128, byte]
  # Padding data
  let len = min(c.msg.data.len, 128) - 1
  assign(input.toOpenArray(0, len), c.msg.data.toOpenArray(0, len))
  let
    p1 = ? G1.getPoint(input.toOpenArray(0, 63))
    p2 = ? G1.getPoint(input.toOpenArray(64, 127))
    apo = (p1 + p2).toAffine()

  c.output.setLen(64)
  if isSome(apo):
    # we can discard here because we supply proper buffer
    discard apo.get().toBytes(c.output)

  ok()

func bn256ecMulImpl*(c: Computation): EvmResultVoid  =
  var
    input: array[96, byte]
  # Padding data
  let len = min(c.msg.data.len, 96) - 1
  assign(input.toOpenArray(0, len), c.msg.data.toOpenArray(0, len))
  let
    p1 = ? G1.getPoint(input.toOpenArray(0, 63))
    fr = ? getFR(input.toOpenArray(64, 95))
    apo = (p1 * fr).toAffine()

  c.output.setLen(64)
  if isSome(apo):
    # we can discard here because we supply buffer of proper size
    discard apo.get().toBytes(c.output)

  ok()

func bn256ecPairingImpl*(c: Computation): EvmResultVoid  =
  let msglen = c.msg.data.len
  if msglen == 0:
    # we can discard here because we supply buffer of proper size
    c.output.setLen(32)
    discard BNU256.one().toBytesBE(c.output)
  else:
    # Calculate number of pairing pairs
    let count = msglen div 192
    # Pairing accumulator
    var acc = FQ12.one()

    for i in 0..<count:
      let
        s = i * 192
        # Loading AffinePoint[G1], bytes from [0..63]
        p1 = ?G1.getPoint(c.msg.data.toOpenArray(s, s + 63))
        # Loading AffinePoint[G2], bytes from [64..191]
        p2 = ?G2.getPoint(c.msg.data.toOpenArray(s + 64, s + 191))

      # Accumulate pairing result
      acc = acc * pairing(p1, p2)

    c.output.setLen(32)
    if acc == FQ12.one():
      # we can discard here because we supply buffer of proper size
      discard BNU256.one().toBytesBE(c.output)

  ok()
