# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Benchmark: precompile cache speedup vs. disabled, across cache hit rates.
#
# bench_precompiles.nim times each precompile's single worst-case input repeated
# - i.e. a 100%-hit steady state, which flatters the cache enormously. This
# benchmark asks the practical question instead: for a realistic mix where only
# a fraction of lookups hit, is the cache a net win for the run overall?
#
# For each cached precompile we pick an *average* input - the median-compute-cost
# valid fixture input, not the worst case (pathological inputs above a cost cap,
# e.g. blake2f with millions of rounds, are excluded from the median) - and time
# a sequence of calls at several hit rates with the cache enabled vs disabled.
#
#   speedup = (disabled compute ns) / (enabled ns at that hit rate)
#   > 1  cache is faster;  < 1  cache is a net loss
#
# A miss is forced by evicting the entry just before the call (a small, documented
# overhead). The cache holds a single entry, so probe lengths are best-case - this
# slightly understates real overhead, so treat low-hit-rate speedups as optimistic.
#
#   nim c -d:release -o:build/bench_precompile_cache_hitrate \
#     tests/bench_precompile_cache_hitrate.nim
#   ./build/bench_precompile_cache_hitrate

import
  std/[json, os, strutils, monotimes, times, algorithm, math],
  stew/byteutils,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/common/common,
  ../tools/common/helpers as chp,
  ../execution_chain/[
    evm/computation,
    evm/state,
    evm/types,
    constants,
    concurrency/lru,
    evm/precompiles {.all.}],
  eth/common/base

const
  fixtureDir = "tests/fixtures/PrecompileTests"
  warmupIters = 20
  budgetNs = 150_000_000'i64       # ~0.15s of timed work per (precompile, scenario)
  calibIters = 5                   # cost samples per fixture input when picking the median
  costCapNs = 5_000_000.0          # exclude inputs slower than this from the "average"
  hitRates = [5, 25, 50, 75, 95, 100]

# precompile -> (fixture file, cache key capacity in bytes). Only the cached
# precompiles are listed; pointEvaluation needs a trusted setup and is omitted
# (matching bench_precompiles.nim).
const cases = [
  (paEcRecover,     "ecrecover.json",          128),
  (paSha256,        "sha256.json",             256),
  (paModExp,        "modexp_eip7883.json",    1024),
  (paEcAdd,         "bn256Add_istanbul.json",  128),
  (paEcMul,         "bn256mul_istanbul.json",   96),
  (paPairing,       "pairing_istanbul.json",   768),
  (paBlake2bf,      "blake2F.json",            213),
  (paBlsG1Add,      "blsG1Add.json",           256),
  (paBlsG1MultiExp, "blsG1MultiExp.json",      640),
  (paBlsG2Add,      "blsG2Add.json",           512),
  (paBlsG2MultiExp, "blsG2MultiExp.json",     1152),
  (paBlsPairing,    "blsPairing.json",        1536),
  (paBlsMapG1,      "blsMapG1.json",            64),
  (paBlsMapG2,      "blsMapG2.json",            128),
  (paP256Verify,    "P256Verify.json",         160),
]

proc validInputs(file: string, keyCap: int): seq[seq[byte]] =
  ## All valid (non-error) fixture inputs that fit this precompile's cache key.
  let fixture = json.parseFile(fixtureDir / file)
  for test in fixture["data"]:
    if not test.hasKey("ExpectedError") and
       test.hasKey("Input") and test["Input"].getStr.len > 0:
      let input = test["Input"].getStr.hexToSeqByte
      if input.len <= keyCap:
        result.add input
  doAssert result.len > 0, "no valid cacheable input in " & file

proc newVmState(): BaseVMState =
  let
    conf = getChainConfig("Osaka")
    com = CommonRef.new(newCoreDbRef DefaultDbMemory, config = conf)
  BaseVMState.new(
    Header(number: 1'u64, stateRoot: EMPTY_ROOT_HASH),
    Header(), com, com.db.baseTxFrame())

proc newComp(vmState: BaseVMState, precompile: Precompiles,
             input: seq[byte]): Computation =
  let msg = Message(
    kind: CallKind.Call,
    gas: 1_000_000_000,
    contractAddress: precompileAddrs[precompile],
    codeAddress: precompileAddrs[precompile],
    data: input,
    flags: {MsgFlags.Precompile})
  newComputation(vmState, false, msg)

proc run(c: Computation, precompile: Precompiles) {.inline.} =
  c.gasMeter.gasRemaining = 1_000_000_000
  c.output.setLen(0)
  c.error = nil
  c.execPrecompile(precompile)

proc evict(precompile: Precompiles, input: openArray[byte]) =
  ## Drop this precompile's cached entry (same key the cache builds for `input`)
  ## so the next call is a miss. The cache must be enabled.
  template d(cache: untyped) =
    cache.del(cache.toCacheKey(input))
  case precompile
  of paEcRecover: d(ecRecoverCache)
  of paSha256: d(sha256Cache)
  of paRipeMd160, paIdentity: discard # not cached
  of paModExp: d(modExpCache)
  of paEcAdd: d(ecAddCache)
  of paEcMul: d(ecMulCache)
  of paPairing: d(pairingCache)
  of paBlake2bf: d(blake2bfCache)
  of paPointEvaluation: d(pointEvaluationCache)
  of paBlsG1Add: d(blsG1AddCache)
  of paBlsG1MultiExp: d(blsG1MultiExpCache)
  of paBlsG2Add: d(blsG2AddCache)
  of paBlsG2MultiExp: d(blsG2MultiExpCache)
  of paBlsPairing: d(blsPairingCache)
  of paBlsMapG1: d(blsMapG1Cache)
  of paBlsMapG2: d(blsMapG2Cache)
  of paP256Verify: d(p256VerifyCache)

proc disposeAllCaches() =
  template z(cache: untyped) =
    cache.dispose()
    reset(cache)
  z ecRecoverCache
  z sha256Cache
  z modExpCache
  z ecAddCache
  z ecMulCache
  z pairingCache
  z blake2bfCache
  z pointEvaluationCache
  z blsG1AddCache
  z blsG1MultiExpCache
  z blsG2AddCache
  z blsG2MultiExpCache
  z blsPairingCache
  z blsMapG1Cache
  z blsMapG2Cache
  z p256VerifyCache

# ----------------------------------------------------------------------------
# Timing
# ----------------------------------------------------------------------------

proc timeCompute(vmState: BaseVMState, precompile: Precompiles,
                 input: seq[byte]): float =
  ## ns/call, cache disabled (raw compute). Caller sets precompileCacheActive = false.
  let c = newComp(vmState, precompile, input)
  for _ in 0 ..< warmupIters:
    run(c, precompile)
  var iters = 0
  let start = getMonoTime()
  while true:
    run(c, precompile)
    inc iters
    if (iters and 0x3F) == 0 and (getMonoTime() - start).inNanoseconds >= budgetNs:
      break
  (getMonoTime() - start).inNanoseconds.float / iters.float

proc timeEnabled(vmState: BaseVMState, precompile: Precompiles,
                 input: seq[byte], hitRatePct: int): float =
  ## ns/call, cache enabled, with hitRatePct% of calls hitting and the rest
  ## forced to miss by eviction. Caller has the caches initialized & active.
  let c = newComp(vmState, precompile, input)
  run(c, precompile) # warm: ensure the entry is present
  for _ in 0 ..< warmupIters:
    run(c, precompile)
  var acc = 0
  template once() =
    acc += hitRatePct
    if acc >= 100:
      acc -= 100 # hit: leave the entry in place
    else:
      evict(precompile, input) # miss: drop it -> miss + compute + put
    run(c, precompile)
  var iters = 0
  let start = getMonoTime()
  while true:
    once()
    inc iters
    if (iters and 0x3F) == 0 and (getMonoTime() - start).inNanoseconds >= budgetNs:
      break
  (getMonoTime() - start).inNanoseconds.float / iters.float

proc avgInput(vmState: BaseVMState, precompile: Precompiles, file: string,
              keyCap: int): seq[byte] =
  ## The median-compute-cost valid fixture input - a representative "average"
  ## call. Inputs slower than costCapNs (pathological worst cases) are excluded.
  let inputs = validInputs(file, keyCap)
  if inputs.len == 1:
    return inputs[0]
  var
    ranked: seq[(float, seq[byte])]
    cheapest = (float.high, inputs[0])
  for inp in inputs:
    let c = newComp(vmState, precompile, inp)
    run(c, precompile) # warmup
    var best = float.high
    for _ in 0 ..< calibIters:
      let s = getMonoTime()
      run(c, precompile)
      best = min(best, (getMonoTime() - s).inNanoseconds.float)
    if best < cheapest[0]:
      cheapest = (best, inp)
    if best <= costCapNs:
      ranked.add (best, inp)
  if ranked.len == 0: # everything was pathologically slow - fall back to cheapest
    return cheapest[1]
  ranked.sort(proc(x, y: (float, seq[byte])): int = cmp(x[0], y[0]))
  ranked[ranked.len div 2][1]

proc runSweep(vmState: BaseVMState, threadSafe: bool,
              work: seq[tuple[precompile: Precompiles, input: seq[byte]]]) =
  disposeAllCaches()
  initPrecompileCaches(threadSafe)

  # disabled compute cost per precompile
  precompileCacheActive = false
  var compute: seq[float]
  for w in work:
    compute.add timeCompute(vmState, w.precompile, w.input)

  # enabled cost at each hit rate
  precompileCacheActive = true
  var enabled: seq[array[hitRates.len, float]]
  for w in work:
    var row: array[hitRates.len, float]
    for hi, hr in hitRates:
      row[hi] = timeEnabled(vmState, w.precompile, w.input, hr)
    enabled.add row

  # ----- report -----
  echo "precompile cache speedup vs disabled, by hit rate (fork=", vmState.fork,
       ", threadSafe=", threadSafe, ")"
  echo "speedup = compute / enabled;  >1.0 cache faster, <1.0 net loss;  ",
       "miss forced by eviction"
  stdout.write align("precompile", 18), align("compute ns", 13), "  "
  for hr in hitRates:
    stdout.write align($hr & "%", 9)
  echo align("input B", 9)

  var
    sumCompute = 0.0
    sumEnabled: array[hitRates.len, float]
    logSpeedup: array[hitRates.len, float]
  for wi, w in work:
    stdout.write align($w.precompile, 18),
      align(formatFloat(compute[wi], ffDecimal, 1), 13), "  "
    for hi in 0 ..< hitRates.len:
      let sp = compute[wi] / enabled[wi][hi]
      stdout.write align(formatFloat(sp, ffDecimal, 2) & "x", 9)
      sumEnabled[hi] += enabled[wi][hi]
      logSpeedup[hi] += ln(sp)
    echo align($w.input.len, 9)
    sumCompute += compute[wi]

  # overall: a run calling each precompile once (cost-weighted -> dominated by
  # the expensive precompiles)
  stdout.write align("OVERALL sum", 18),
    align(formatFloat(sumCompute, ffDecimal, 1), 13), "  "
  for hi in 0 ..< hitRates.len:
    stdout.write align(formatFloat(sumCompute / sumEnabled[hi], ffDecimal, 2) & "x", 9)
  echo align("each x1", 9)

  # overall: geometric mean of per-precompile speedups (equal weight, cost-independent)
  stdout.write align("OVERALL geomean", 18), align("-", 13), "  "
  for hi in 0 ..< hitRates.len:
    let g = exp(logSpeedup[hi] / work.len.float)
    stdout.write align(formatFloat(g, ffDecimal, 2) & "x", 9)
  echo align("equal wt", 9)

proc main() =
  let vmState = newVmState()

  # Calibrate the average input per precompile with the cache off.
  precompileCacheActive = false
  var work: seq[tuple[precompile: Precompiles, input: seq[byte]]]
  for (precompile, file, keyCap) in cases:
    work.add (precompile, avgInput(vmState, precompile, file, keyCap))

  runSweep(vmState, threadSafe = false, work)
  echo ""
  runSweep(vmState, threadSafe = true, work)

main()
