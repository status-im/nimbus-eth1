# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[monotimes, times, random, strutils],
  unittest2, stew/byteutils,
  ../execution_chain/evm/blake2b_f

const
  eip152Vector5 =
    "0000000c48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f" &
    "3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e13" &
    "19cde05b61626300000000000000000000000000000000000000000000000000" &
    "0000000000000000000000000000000000000000000000000000000000000000" &
    "0000000000000000000000000000000000000000000000000000000000000000" &
    "0000000000000000000000000000000000000000000000000000000000000000" &
    "000000000300000000000000000000000000000001"
  eip152Vector5Expected =
    "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1" &
    "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"

proc withRounds(input: openArray[byte], rounds: uint32): seq[byte] =
  result = @input
  result[0] = byte(rounds shr 24)
  result[1] = byte(rounds shr 16)
  result[2] = byte(rounds shr 8)
  result[3] = byte(rounds)

suite "blake2b_F benchmark":
  let baseInput = hexToSeqByte(eip152Vector5)

  test "C implementation matches EIP-152 vector":
    var output: array[64, byte]
    check blake2b_F(baseInput, output)
    check output.toHex == eip152Vector5Expected

  test "C implementation matches Nim implementation":
    var rng = initRand(152)
    for iteration in 0 ..< 200:
      var input = newSeq[byte](213)
      for i in 0 ..< 212:
        input[i] = byte(rng.rand(255))
      input[212] = byte(rng.rand(1))
      let rounds = uint32(rng.rand(100))
      input = input.withRounds(rounds)

      var
        outputC: array[64, byte]
        outputNim: array[64, byte]
      check blake2b_F(input, outputC)
      check blake2b_F_nim(input, outputNim)
      check outputC == outputNim

  test "benchmark C vs Nim":
    # Fixed total amount of compression rounds per implementation so that every
    # `rounds` variation performs a comparable amount of work.
    const
      totalRounds = 24_000_000
      # Number of independent timed runs; the fastest (least noisy) is reported.
      repeats = 3

    template bench(fn: untyped, benchInput: seq[byte], iterations: int): Duration =
      block:
        var output: array[64, byte]
        # Warmup (~1/8 of the timed work) to prime caches and let the CPU ramp up.
        for i in 0 ..< max(1, iterations div 8):
          doAssert fn(benchInput, output)
        var best = initDuration(seconds = 1_000_000)
        for r in 0 ..< repeats:
          let start = getMonoTime()
          for i in 0 ..< iterations:
            doAssert fn(benchInput, output)
          best = min(best, getMonoTime() - start)
        best

    for rounds in [1'u32, 12'u32, 100'u32, 1_000'u32,
                   10_000'u32, 100_000'u32, 1_000_000'u32]:
      let
        input = baseInput.withRounds(rounds)
        iterations = max(1, totalRounds div int(rounds))
        nimTime = bench(blake2b_F_nim, input, iterations)
        cTime = bench(blake2b_F, input, iterations)
        speedup = nimTime.inNanoseconds.float / cTime.inNanoseconds.float

      echo "rounds=", ($rounds).align(9),
        " iterations=", ($iterations).align(9),
        " nim=", ($nimTime.inMicroseconds).align(8), "us",
        " c=", ($cTime.inMicroseconds).align(8), "us",
        " speedup=", speedup.formatFloat(ffDecimal, 2), "x"

      # At rounds=1 per-call FFI/copy overhead dominates and the C path can be
      # marginally slower; the SIMD win only shows once compression work
      # matters.
      if rounds >= 12:
        check cTime < nimTime
