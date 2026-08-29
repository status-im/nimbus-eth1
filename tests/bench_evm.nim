# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Throughput benchmark for EVM call frames.
#
# Every call frame allocates a 32kb EVM stack and an EVM memory buffer, so the
# cost of creating and tearing down a frame dominates workloads that make many
# short calls - which on mainnet includes the most common transaction of all, a
# plain value transfer. The workloads below are built so that the per-frame cost
# is the variable under test:
#
#   * `call/empty`      - loop of CALLs to an account with no code, ie the
#                         cheapest possible frame. Almost pure frame overhead.
#   * `call/mem-8kb`    - same, but the callee grows its memory to 8kb, which is
#                         within the range a pooled memory buffer is retained.
#   * `call/mem-128kb`  - same, but past the retention limit, so the buffer is
#                         released rather than pooled.
#   * `arith`           - control: one frame, a tight arithmetic loop. Any change
#                         here is noise or a regression, never a win.
#
# Timings are per loop iteration, which for the `call/*` workloads is one child
# call frame, taken from the fastest of `repeats` runs.
#
# Comparing two builds is only good to about +-5%: code layout alone moves these
# numbers by that much, in either direction, and it does not cancel out across
# runs. To measure a change in the EVM properly, make the two arms toggleable
# within one binary so both share a layout, and pair the samples.
#
# Build with stack traces off or the numbers are meaningless:
#
#   ./env.sh nim c -r -d:release -d:disable_libbacktrace \
#     --stacktrace:off --linetrace:off --excessiveStackTrace:off \
#     -d:chronicles_log_level=ERROR tests/bench_evm.nim

{.used.}

import
  std/[strformat, strutils, times],
  unittest2,
  stint,
  eth/common/[addresses, base],
  ../execution_chain/db/ledger,
  ../execution_chain/evm/state,
  ../execution_chain/evm/types,
  ../execution_chain/transaction/call_evm,
  ./macro_assembler

const
  benchFork = "Prague"
  repeats = 30
  warmups = 3
  benchGasLimit = 30_000_000.GasInt

  senderAddr = address"00000000000000000000000000000000000000aa"
  contractAddr = address"00000000000000000000000000000000000000bb"
  calleeAddr = address"00000000000000000000000000000000000000cc"
  emptyAddr = address"00000000000000000000000000000000000000dd"

# ------------------------------------------------------------------------------
# Bytecode
# ------------------------------------------------------------------------------

func push1(v: byte): seq[byte] =
  @[0x60'u8, v]

func push3(v: int): seq[byte] =
  @[0x62'u8, byte(v shr 16), byte((v shr 8) and 0xff), byte(v and 0xff)]

func loopCode(body: openArray[byte], iterations: int): seq[byte] =
  ## `iterations` repetitions of `body`, with the counter kept at the bottom of
  ## the stack. The loop head is a JUMPDEST at pc 3.
  result.add @[0x61'u8, byte(iterations shr 8), byte(iterations and 0xff)]
  result.add 0x5b'u8
  result.add @body
  result.add push1(1)
  result.add @[0x90'u8, 0x03'u8, 0x80'u8]
  result.add push1(3)
  result.add @[0x57'u8, 0x00'u8]

func callBody(target: Address, childGas: int): seq[byte] =
  for _ in 0 ..< 5:
    result.add push1(0)
  result.add 0x73'u8
  result.add @(target.data)
  result.add push3(childGas)
  result.add @[0xf1'u8, 0x50'u8]

func growMemoryCode(size: int): seq[byte] =
  result.add push1(0)
  result.add push3(size - 32)
  result.add @[0x52'u8, 0x00'u8]

const arithBody = [0x60'u8, 0x07, 0x60, 0x05, 0x01, 0x60, 0x03, 0x02, 0x50]

# ------------------------------------------------------------------------------
# Harness
# ------------------------------------------------------------------------------

type
  Workload = object
    name: string
    iterations: int
    code: seq[byte]
    calleeCode: seq[byte]

  Stats = object
    best: float ## fastest of `repeats` runs, which is the least noisy estimator
    perIter: float
    gasUsed: GasInt

proc run(w: Workload): Stats =
  let vmState = initVMEnv(benchFork)
  defer:
    vmState.dispose()

  vmState.ledger.setCode(contractAddr, w.code)
  if w.calleeCode.len > 0:
    vmState.ledger.setCode(calleeAddr, w.calleeCode)

  let params = CallParams(
    vmState: vmState,
    gasPrice: 0.GasInt,
    gasLimit: benchGasLimit,
    sender: senderAddr,
    to: contractAddr,
  )

  for _ in 0 ..< warmups:
    let res = runComputation(params, CallResult)
    doAssert res.error.len == 0, w.name & ": " & res.error

  result.best = Inf
  for _ in 0 ..< repeats:
    let start = cpuTime()
    let res = runComputation(params, CallResult)
    result.best = min(result.best, cpuTime() - start)
    result.gasUsed = res.gasUsed
  result.perIter = result.best / float(w.iterations)

func header(): string =
  alignLeft("workload", 16) & align("ns/iter", 12) & align("iters", 10) &
    align("gas/iter", 10) & align("ms/run", 10)

func line(w: Workload, s: Stats): string =
  alignLeft(w.name, 16) &
    align(&"{s.perIter * 1e9:.1f}", 12) &
    align($w.iterations, 10) &
    align($(s.gasUsed div w.iterations.GasInt), 10) &
    align(&"{s.best * 1e3:.2f}", 10)

# ------------------------------------------------------------------------------
# Workloads
# ------------------------------------------------------------------------------

proc workloads(): seq[Workload] =
  @[
    Workload(
      name: "call/empty",
      iterations: 20_000,
      code: loopCode(callBody(emptyAddr, 4096), 20_000),
    ),
    Workload(
      name: "call/mem-8kb",
      iterations: 12_000,
      code: loopCode(callBody(calleeAddr, 4096), 12_000),
      calleeCode: growMemoryCode(8 * 1024),
    ),
    Workload(
      name: "call/mem-128kb",
      iterations: 500,
      code: loopCode(callBody(calleeAddr, 65_536), 500),
      calleeCode: growMemoryCode(128 * 1024),
    ),
    Workload(
      name: "arith",
      iterations: 50_000,
      code: loopCode(arithBody, 50_000),
    ),
  ]

suite "EVM call frame throughput benchmark":
  test "call frame workloads":
    debugEcho ""
    debugEcho "  fork=", benchFork, ", repeats=", repeats, ", warmups=", warmups
    debugEcho header()
    var total = 0.0
    for w in workloads():
      let s = w.run()
      debugEcho line(w, s)
      total += s.best
    check total > 0.0
