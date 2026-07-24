# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[json, monotimes, os, strformat, times],
  unittest2,
  stew/byteutils,
  ../execution_chain/compile_info,
  ../execution_chain/evm/types

when enable_mcl_lib:
  import ../execution_chain/evm/bncurve_mcl
else:
  import ../execution_chain/evm/bncurve_nim

proc runPairing(input: seq[byte]): (bool, seq[byte]) =
  let c = Computation(msg: Message(data: input))
  let res = bn256ecPairingImpl(c)
  (res.isOk, c.output)

proc loadVectors(name: string): JsonNode =
  parseFile(currentSourcePath.parentDir / "fixtures" / "PrecompileTests" / name)["data"]

proc getInput(vectors: JsonNode, name: string): seq[byte] =
  for t in vectors:
    if t["Name"].getStr == name:
      return hexToSeqByte(t["Input"].getStr)
  doAssert false, "unknown vector: " & name

suite "bn256 pairing precompile":
  test "fixture vectors":
    for fname in ["pairing.json", "pairing_istanbul.json"]:
      for t in loadVectors(fname):
        let
          input = hexToSeqByte(t["Input"].getStr)
          expected = hexToSeqByte(t["Expected"].getStr)
          (ok, output) = runPairing(input)
        check ok
        check output == expected

  test "benchmark":
    let vectors = loadVectors("pairing.json")
    var cases = @[
      ("one_point", getInput(vectors, "one_point")),
      ("jeff1", getInput(vectors, "jeff1")),
      ("jeff4", getInput(vectors, "jeff4")),
      ("ten_point_match_1", getInput(vectors, "ten_point_match_1")),
    ]

    var big: seq[byte]
    let two = getInput(vectors, "two_point_match_2")
    for _ in 0 ..< 10:
      big.add two
    cases.add ("twenty_point", big)

    for (name, input) in cases:
      let (ok, _) = runPairing(input)
      check ok

      const iters = 20
      let start = getMonoTime()
      for _ in 0 ..< iters:
        discard runPairing(input)
      let perOp = (getMonoTime() - start).inMicroseconds div iters
      echo &"  {name}: {input.len div 192} pairs, {perOp} us/op"
