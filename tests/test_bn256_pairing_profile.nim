# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[json, monotimes, os, times]

include ../execution_chain/evm/bncurve_mcl

{.pop.}

proc loadInput(name: string): seq[byte] =
  let vectors = parseFile(
    currentSourcePath.parentDir / "fixtures" / "PrecompileTests" / "pairing.json"
  )["data"]
  for t in vectors:
    if t["Name"].getStr == name:
      return hexToSeqByte(t["Input"].getStr)
  doAssert false, "unknown vector: " & name

template bench(name: string, iters: int, body: untyped) =
  block:
    body
    let start = getMonoTime()
    for _ in 0 ..< iters:
      body
    let ns = (getMonoTime() - start).inNanoseconds div iters
    echo "  " & name & ": " & $ns & " ns/op"

proc main() =
  let
    input = loadInput("ten_point_match_1")
    count = input.len div 192
  echo "input: " & $count & " pairs"

  var
    g1: array[16, BnG1]
    g2: array[16, BnG2]
    gt {.noinit.}: BnGT
    acc {.noinit.}: BnGT

  bench("G1 deserialize x" & $count, 200):
    for i in 0 ..< count:
      doAssert g1[i].deserialize(input.toOpenArray(i * 192, i * 192 + 63))

  bench("G2 deserialize x" & $count & " (frobenius subgroup check)", 200):
    for i in 0 ..< count:
      doAssert g2[i].deserialize(input.toOpenArray(i * 192 + 64, i * 192 + 191))

  mclBn_verifyOrderG2(1.cint)
  bench("G2 deserialize x" & $count & " (mcl order check as well)", 200):
    for i in 0 ..< count:
      doAssert g2[i].deserialize(input.toOpenArray(i * 192 + 64, i * 192 + 191))
  mclBn_verifyOrderG2(0.cint)

  bench("G2 isInSubgroup x" & $count, 200):
    for i in 0 ..< count:
      doAssert g2[i].isInSubgroup()

  bench("G2 isValidOrder (mcl) x" & $count, 200):
    for i in 0 ..< count:
      doAssert mclBnG2_isValidOrder(g2[i].addr) == 1.cint

  const
    sixZSqr = [
      0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0x6f, 0x4d, 0x82, 0x48, 0xee, 0xb8, 0x59, 0xfb,
      0xf8, 0x3e, 0x96, 0x82, 0xe8, 0x7c, 0xfd, 0x46]
    fullScalar = [
      0x2f'u8, 0x4d, 0x82, 0x48, 0xee, 0xb8, 0x59, 0xfb,
      0xf8, 0x3e, 0x96, 0x82, 0xe8, 0x7c, 0xfd, 0x46,
      0x6f, 0x4d, 0x82, 0x48, 0xee, 0xb8, 0x59, 0xfb,
      0xf8, 0x3e, 0x96, 0x82, 0xe8, 0x7c, 0xfd, 0x46]
  var
    frSmall {.noinit.}: BnFr
    frFull {.noinit.}: BnFr
    q {.noinit.}: BnG2
  doAssert frSmall.deserialize(sixZSqr)
  doAssert frFull.deserialize(fullScalar)

  bench("G2 mul by 6z^2 (127 bit) x" & $count, 200):
    for i in 0 ..< count:
      mclBnG2_mul(q.addr, g2[i].addr, frSmall.addr)

  bench("G2 mul by full 254 bit scalar x" & $count, 200):
    for i in 0 ..< count:
      mclBnG2_mul(q.addr, g2[i].addr, frFull.addr)

  bench("millerLoopVec x" & $count, 200):
    mclBn_millerLoopVec(acc.addr, g1[0].addr, g2[0].addr, mclSize count)

  bench("finalExp", 200):
    mclBn_finalExp(gt.addr, acc.addr)

main()
