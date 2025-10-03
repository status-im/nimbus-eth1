# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[monotimes, times, strformat],
  eth/common,
  nimcrypto/keccak,
  constantine/hashes/h_keccak

type
  KECCACK256* = h_keccak.KeccakContext[256, 0x01]

func keccak_nimcrypto*(input: openArray[byte]): Hash32 =
  var ctx: keccak.keccak256
  ctx.update(input)
  ctx.finish().to(Hash32)

func keccak_nimcrypto*(input: openArray[char]): Hash32 =
  keccak_nimcrypto(input.toOpenArrayByte(0, input.high))

func keccak_constantine*(input: openArray[byte]): Hash32 =
  var
    ctx: KECCACK256
    buff: array[32, byte]
  ctx.update(input)
  ctx.finish(buff)
  Hash32(buff)

func keccak_constantine*(input: openArray[char]): Hash32 =
  keccak_constantine(input.toOpenArrayByte(0, input.high))

const
  INPUT_32_BYTE = "1234567890abcdef1234567890abcdef"
  INPUT_64_BYTE = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
  INPUT_128_BYTE = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
  INPUT_256_BYTE = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

# Utility: turn string into a seq[byte] once, to avoid per-iter conversion costs.
proc toBytesOnce(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    # Copy raw bytes of the string into result
    when compiles(copyMem):
      copyMem(addr result[0], unsafeAddr s[0], s.len)
    else:
      for i, c in s: result[i] = byte(c)

# Benchmark runner
proc bench(name: string,
           hashFn: proc(data: openArray[byte]): Hash32 {.noSideEffect.},
           data: openArray[byte],
           iters: int) =
  # Warm-up
  var acc: uint32 = 0
  for _ in 0 ..< min(iters, 10_000):
    let h = hashFn(data)
    # consume 4 bytes to avoid DCE; Hash32 is 32 bytes
    acc = acc xor cast[ptr uint32](unsafeAddr h)[]

  # Timed run
  let start = getMonoTime()
  for _ in 0 ..< iters:
    let h = hashFn(data)
    acc = acc xor cast[ptr uint32](unsafeAddr h)[]
  let dur = getMonoTime() - start

  # Metrics
  let nsTotal = dur.inNanoseconds.float
  let nsPerOp = nsTotal / iters.float
  let bytesPerOp = data.len.float
  let mbps = (bytesPerOp * iters.float) / (dur.inSeconds.float * 1024.0 * 1024.0)

  echo fmt"{name:>30} | size={data.len:>4}  iters={iters:>9}  ns/op={nsPerOp:>10.1f}  MB/s={mbps:>8.1f}  (acc={acc})"

# Choose iteration counts to keep each test ~200–400ms on a typical dev box.
# Scale inversely with input length so total hashed bytes per test are similar.
proc chooseIters(size: int): int =
  let targetBytes = 64 * 1024 * 1024           # ~64 MiB per test
  max(1, targetBytes div max(1, size))


type DataKind = enum
  dkZeros, dkPattern, dkPRG

proc genData(kind: DataKind; size: int; seed: string = "eth-blocks"): seq[byte] =
  ## Deterministic payload generator for benchmarking.
  result = newSeq[byte](size)
  case kind
  of dkZeros:
    # already zero-initialized
    discard
  of dkPattern:
    # Convert pattern string to an addressable array
    const patStr = "1234567890abcdef"
    var pat: array[patStr.len, byte]
    for i, c in patStr:
      pat[i] = byte(c)

    var i = 0
    while i < size:
      let chunk = min(pat.len, size - i)
      when compiles(copyMem):
        copyMem(addr result[i], addr pat[0], chunk)
      else:
        for j in 0 ..< chunk:
          result[i + j] = pat[j]
      i += chunk

  of dkPRG:
    # Keccak(counter | seed) stream; reproducible across runs.
    var off = 0
    var ctr: uint64 = 0
    var outblk: array[32, byte]
    while off < size:
      var ctx: keccak.keccak256
      ctx.update(cast[array[8, byte]](ctr))      # little-endian ctr bytes
      ctx.update(seed)
      let digest = ctx.finish()
      # Write 32 bytes at a time
      when compiles(copyMem):
        copyMem(addr outblk[0], unsafeAddr digest.data[0], 32)
      else:
        for i in 0 ..< 31: outblk[i] = digest.data[i]
      let chunk = min(32, size - off)
      when compiles(copyMem):
        copyMem(addr result[off], addr outblk[0], chunk)
      else:
        for i in 0 ..< chunk: result[off + i] = outblk[i]
      inc ctr
      inc off, chunk

# Suggested EL-like sizes (bytes)
const BlockSizes = [
  32 * 1024,         # 32 KiB
  64 * 1024,         # 64 KiB
  128 * 1024,        # 128 KiB
  256 * 1024,        # 256 KiB
  512 * 1024,        # 512 KiB
  1 * 1024 * 1024,   # 1 MiB (stress)
  2 * 1024 * 1024,   # 2 MiB (stress)
  4 * 1024 * 1024,
  5 * 1024 * 1024,
  6 * 1024 * 1024
]

when isMainModule:
  let inputs = [
    ("32B",  INPUT_32_BYTE.toBytesOnce()),
    ("64B",  INPUT_64_BYTE.toBytesOnce()),
    ("128B", INPUT_128_BYTE.toBytesOnce()),
    ("256B", INPUT_256_BYTE.toBytesOnce())
  ]

  echo "== Keccak Bench: nimcrypto vs constantine =="
  for (label, buf) in inputs:
    let iters = chooseIters(buf.len)
    bench(&"nimcrypto {label}", keccak_nimcrypto, buf, iters)
    bench(&"constantine {label}", keccak_constantine, buf, iters)

  for sz in BlockSizes:
    for kind in [dkZeros, dkPattern, dkPRG]:
      let label =
        (case kind
         of dkZeros:   "zeros"
         of dkPattern: "pattern"
         of dkPRG:     "prg")
      let buf = genData(kind, sz)
      let iters = chooseIters(buf.len)       # reuse your chooseIters()
      bench(fmt"nimcrypto {label} {sz div 1024}KiB", keccak_nimcrypto, buf, iters)
      bench(fmt"constantine {label} {sz div 1024}KiB", keccak_constantine, buf, iters)

