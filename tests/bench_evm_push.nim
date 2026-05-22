# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM PUSH hot-path microbenchmark.
##
## Isolates the impact of `{.inline.}` on `stack.push`. The "before" row routes
## every push through a {.noinline.} wrapper to force a real call frame at the
## push site (mimicking the pre-change codegen, where `push_s256` showed up as
## its own VTune symbol). The "after" row calls `stack.push` directly, letting
## the {.inline.} hint propagate.
##
## Build & run:
##   ./env.sh nim c -d:release -r -o:build/bench_evm_push tests/bench_evm_push.nim

{.used.}

import
  std/[monotimes, strformat, strutils, times],
  stint,
  ../execution_chain/evm/[stack, code_stream, code_bytes, evm_errors]

const
  pushesPerBatch = 1000          # < 1024 EVM stack limit
  batches = 10_000
  totalPushes = pushesPerBatch * batches

proc reportTiming(label: string; ops: int; ns: float): float =
  let nsPerOp = ns / ops.float
  let mops = ops.float / (ns / 1e9) / 1e6
  echo &"{label:<46} {nsPerOp:>8.2f} ns/op   {mops:>8.2f} Mops/s"
  nsPerOp

# {.noinline.} forces the C compiler to keep this as a real call site even
# though `stack.push` itself is `{.inline.}`. That gives us a faithful proxy
# for the pre-change behavior, where `push` had no inline hint and showed
# up as its own symbol in profiles.
proc pushBoxed(stack: EvmStack, v: UInt256): EvmResultVoid {.noinline.} =
  stack.push(v)

proc makeImmBytes(nBytes: int): seq[byte] =
  result = newSeq[byte](nBytes)
  for i in 0 ..< nBytes:
    result[i] = byte((i * 31 + 7) and 0xff)

proc benchBefore(n: static int): float {.noinline.} =
  ## Before {.inline.}: every push goes through a real call frame.
  let codeBytes = makeImmBytes(n * pushesPerBatch + 32)
  var c = CodeStream.init(CodeBytesRef.init(codeBytes))
  let stack = EvmStack.init()
  defer: stack.dispose()

  # Warm up so the first batch doesn't get charged for page faults.
  for _ in 0 ..< pushesPerBatch:
    doAssert pushBoxed(stack, c.readVmWord(n)).isOk
  stack.len = 0
  c.pc = 0

  var sink: uint64 = 0
  let t0 = getMonoTime()
  for _ in 0 ..< batches:
    stack.len = 0
    c.pc = 0
    for _ in 0 ..< pushesPerBatch:
      doAssert pushBoxed(stack, c.readVmWord(n)).isOk
    # Force the writes to be observed so the C compiler can't elide them.
    sink = sink xor stack.lsPeekInt(^1).limbs[0]
  let ns = (getMonoTime() - t0).inNanoseconds.float
  let label = &"BEFORE PUSH{n} (noinline call to push)"
  result = reportTiming(label, totalPushes, ns)
  echo &"  (sink={sink:#x})"

proc benchAfter(n: static int): float {.noinline.} =
  ## After {.inline.}: push folds into the caller, no call frame.
  let codeBytes = makeImmBytes(n * pushesPerBatch + 32)
  var c = CodeStream.init(CodeBytesRef.init(codeBytes))
  let stack = EvmStack.init()
  defer: stack.dispose()

  for _ in 0 ..< pushesPerBatch:
    doAssert stack.push(c.readVmWord(n)).isOk
  stack.len = 0
  c.pc = 0

  var sink: uint64 = 0
  let t0 = getMonoTime()
  for _ in 0 ..< batches:
    stack.len = 0
    c.pc = 0
    for _ in 0 ..< pushesPerBatch:
      doAssert stack.push(c.readVmWord(n)).isOk
    sink = sink xor stack.lsPeekInt(^1).limbs[0]
  let ns = (getMonoTime() - t0).inNanoseconds.float
  let label = &"AFTER  PUSH{n} (inline push)"
  result = reportTiming(label, totalPushes, ns)
  echo &"  (sink={sink:#x})"

proc runFor(n: static int) =
  echo &"--- PUSH{n} ---"
  let beforeNs = benchBefore(n)
  let afterNs = benchAfter(n)
  let speedup = beforeNs / afterNs
  let pctSaved = (1.0 - afterNs / beforeNs) * 100.0
  echo &"  speedup: {speedup:.2f}x   (saved {pctSaved:.1f}% per push)"
  echo ""

proc main() =
  echo &"PUSH inline benchmark — {totalPushes} pushes per measurement"
  echo "-".repeat(78)
  runFor(1)
  runFor(2)
  runFor(8)
  runFor(20)
  runFor(32)

when isMainModule:
  main()
