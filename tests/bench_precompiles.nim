# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Micro-benchmark for the precompile result cache (see precompiles.nim).
#
# Each precompile's most expensive ("slow") input is timed three ways and the
# results are printed side by side:
#   - hit:      cache enabled, same input repeated (steady-state cache hit)
#   - miss:     cache enabled, entry evicted before every call (lookup miss +
#               compute + put). This includes the forced eviction, so it slightly
#               overstates a true single miss - most visible on cheap precompiles.
#   - disabled: cache disabled (the raw precompile cost)
#
#   nim c -d:release -o:build/bench_precompiles tests/bench_precompiles.nim
#   ./build/bench_precompiles

import
  std/[json, os, strutils, monotimes, times],
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
  warmupIters = 100
  budgetNs = 400_000_000'i64   # ~0.4s of timed work per scenario
  blakeSlowRounds = 50_000'u32

# precompile -> fixture file holding a valid (non-error) input
const cases = [
  (paEcRecover,      "ecrecover.json"),
  (paSha256,         "sha256.json"),
  (paRipeMd160,      "ripemd160.json"),
  (paModExp,         "modexp_eip7883.json"),
  (paEcAdd,          "bn256Add_istanbul.json"),
  (paEcMul,          "bn256mul_istanbul.json"),
  (paPairing,        "pairing_istanbul.json"),
  (paBlake2bf,       "blake2F.json"),
  (paBlsG1Add,       "blsG1Add.json"),
  (paBlsG1MultiExp,  "blsG1MultiExp.json"),
  (paBlsG2Add,       "blsG2Add.json"),
  (paBlsG2MultiExp,  "blsG2MultiExp.json"),
  (paBlsPairing,     "blsPairing.json"),
  (paBlsMapG1,       "blsMapG1.json"),
  (paBlsMapG2,       "blsMapG2.json"),
  (paP256Verify,     "P256Verify.json"),
]

# Variable-input precompiles: time the smallest vs largest cacheable (<=512B)
# fixture input rather than a constructed fast/slow pair.
const sizeVarying = {
  paModExp, paPairing, paBlsG1MultiExp, paBlsG2MultiExp, paBlsPairing}

proc validInputs(file: string): seq[seq[byte]] =
  ## All valid (non-error) fixture inputs that fit the cache key buffer,
  ## sorted ascending by length.
  let fixture = json.parseFile(fixtureDir / file)
  for test in fixture["data"]:
    if not test.hasKey("ExpectedError") and
       test.hasKey("Input") and test["Input"].getStr.len > 0:
      let input = test["Input"].getStr.hexToSeqByte
      if input.len <= 512:
        result.add input
  doAssert result.len > 0, "no valid bounded input in " & file
  # simple insertion sort by length (input lists are tiny)
  for i in 1 ..< result.len:
    var j = i
    while j > 0 and result[j-1].len > result[j].len:
      swap(result[j-1], result[j]); dec j

proc padded(input: openArray[byte], n: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< min(n, input.len):
    result[i] = input[i]

# Construct (fastInput, slowInput) for a precompile from its valid fixture inputs
# (sorted ascending by length).
proc scenarios(precompile: Precompiles, inputs: seq[seq[byte]]):
    tuple[fast, slow: seq[byte], note: string] =
  if precompile in sizeVarying:
    # smallest vs largest cacheable fixture input
    let fast = inputs[0]
    let slow = inputs[^1]
    return (fast, slow, $fast.len & "B vs " & $slow.len & "B input")

  let fixture = inputs[0]
  case precompile
  of paSha256, paRipeMd160:
    # Cost scales with input length; cache only stores inputs <= 512 bytes.
    # FAST: empty input. SLOW: largest cacheable input (512 bytes).
    (newSeq[byte](0), newSeq[byte](512), "0B vs 512B input (max cacheable)")
  of paEcAdd:
    # FAST: infinity + infinity (all zeros, the cheap early-out).
    # SLOW: two real curve points (a genuine field-arithmetic addition).
    # inputs[0] is the shortest fixture, which is all-zeros (infinity) and would
    # measure the same trivial path as FAST; pick a full 128-byte input whose
    # first point is non-zero instead.
    var slow = padded(fixture, 128)
    for inp in inputs:
      if inp.len >= 128 and inp[0] != 0:
        slow = padded(inp, 128)
        break
    (newSeq[byte](128), slow, "0+0 vs P+Q")
  of paEcMul:
    # Same point; FAST scalar = 0 (-> infinity), SLOW scalar = 2^256-1.
    var fast = padded(fixture, 96)
    var slow = padded(fixture, 96)
    for i in 64 ..< 96:
      fast[i] = 0x00
      slow[i] = 0xFF
    (fast, slow, "scalar 0 vs 2^256-1")
  of paBlake2bf:
    # FAST: 0 rounds. SLOW: many rounds (first 4 big-endian bytes).
    var fast = padded(fixture, 213)
    var slow = padded(fixture, 213)
    fast[0] = 0; fast[1] = 0; fast[2] = 0; fast[3] = 0
    slow[0] = byte(blakeSlowRounds shr 24)
    slow[1] = byte(blakeSlowRounds shr 16)
    slow[2] = byte(blakeSlowRounds shr 8)
    slow[3] = byte(blakeSlowRounds)
    (fast, slow, "0 vs " & $blakeSlowRounds & " rounds")
  of paBlsG1Add:
    (newSeq[byte](256), padded(fixture, 256), "0+0 vs P+Q")
  of paBlsG2Add:
    (newSeq[byte](512), padded(fixture, 512), "0+0 vs P+Q")
  of paBlsMapG1:
    (newSeq[byte](64), padded(fixture, 64), "fe=0 vs fe (~constant)")
  of paBlsMapG2:
    (newSeq[byte](128), padded(fixture, 128), "fe=0 vs fe (~constant)")
  of paP256Verify:
    # FAST: zeroed public key -> bound check fails fast (still returns ok).
    # SLOW: valid signature -> full verification.
    var fast = padded(fixture, 160)
    for i in 96 ..< 160: fast[i] = 0
    (fast, padded(fixture, 160), "invalid pk vs full verify")
  else:
    # ecRecover: only the full-recovery path is cacheable (constant cost).
    (fixture, fixture, "constant (no cheap cacheable path)")

proc newVmState(): BaseVMState =
  let
    conf = getChainConfig("Osaka")
    com = CommonRef.new(newCoreDbRef DefaultDbMemory, config = conf)
  BaseVMState.new(
    Header(number: 1'u64, stateRoot: EMPTY_ROOT_HASH),
    Header(),
    com,
    com.db.baseTxFrame())

proc run(c: Computation, precompile: Precompiles) {.inline.} =
  c.gasMeter.gasRemaining = 1_000_000_000
  c.output.setLen(0)
  c.error = nil
  c.execPrecompile(precompile)

proc evict(precompile: Precompiles, input: openArray[byte]) =
  ## Remove this precompile's cached entry (using the same key the cache builds
  ## for `input`) so the next call is a cache miss. The cache must be enabled.
  template d(cache: untyped) =
    cache.del(cache.toCacheKey(input))
  case precompile
  of paEcRecover: d(ecRecoverCache)
  of paSha256, paRipeMd160, paIdentity: discard # not cached
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

proc bench(vmState: BaseVMState, precompile: Precompiles, input: seq[byte],
           forceMiss: bool): float =
  let msg = Message(
    kind: CallKind.Call,
    gas: 1_000_000_000,
    contractAddress: precompileAddrs[precompile],
    codeAddress: precompileAddrs[precompile],
    data: input,
    flags: {MsgFlags.Precompile})
  let c = newComputation(vmState, false, msg)

  template once() =
    if forceMiss:
      evict(precompile, input)
    run(c, precompile)

  for _ in 0 ..< warmupIters:
    once()

  var iters = 0
  let start = getMonoTime()
  while true:
    once()
    inc iters
    if (iters and 0x3FF) == 0 and
       (getMonoTime() - start).inNanoseconds >= budgetNs:
      break
  (getMonoTime() - start).inNanoseconds.float / iters.float

proc disposeAllCaches() =
  ## Free and reset every cache back to the UNINITIALIZED state so it can be
  ## re-initialized in a different mode (`init` asserts UNINITIALIZED, and
  ## `dispose` alone leaves it DISPOSED). A no-op on a fresh cache.
  template z(cache: untyped) =
    cache.dispose()
    reset(cache)
  z ecRecoverCache
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

proc runComparison(
    vmState: BaseVMState, threadSafe: bool,
    work: seq[tuple[precompile: Precompiles, input: seq[byte], note: string]]) =
  # Hit (same input repeated) and miss (entry evicted before every call) both
  # need the cache enabled; disabled measures the raw precompile cost. Re-init
  # the caches in the requested mode (dispose any previous run's caches first).
  disposeAllCaches()
  initPrecompileCaches(threadSafe)
  precompileCacheActive = true
  var hit, miss: seq[float]
  for w in work:
    hit.add bench(vmState, w.precompile, w.input, forceMiss = false)
    miss.add bench(vmState, w.precompile, w.input, forceMiss = true)

  precompileCacheActive = false
  var disabled: seq[float]
  for w in work:
    disabled.add bench(vmState, w.precompile, w.input, forceMiss = false)

  echo "precompile cache: hit vs miss vs disabled (fork=", vmState.fork,
    ", threadSafe=", threadSafe,
    ", slow input; miss includes the eviction used to force it)"
  echo align("precompile", 18), align("hit ns", 12), align("miss ns", 12),
       align("disabled ns", 13), align("hit speedup", 13), align("miss ovh", 11),
       "  scenario"
  for i in 0 ..< work.len:
    let
      h = hit[i]
      m = miss[i]
      d = disabled[i]
      hitSpeedup = if h > 0: d / h else: 0.0
      missOverhead = if d > 0: m / d else: 0.0
    echo align($work[i].precompile, 18),
         align(formatFloat(h, ffDecimal, 1), 12),
         align(formatFloat(m, ffDecimal, 1), 12),
         align(formatFloat(d, ffDecimal, 1), 13),
         align(formatFloat(hitSpeedup, ffDecimal, 1) & "x", 13),
         align(formatFloat(missOverhead, ffDecimal, 2) & "x", 11),
         "  ", work[i].note

proc main() =
  let vmState = newVmState()

  # Build the work list once so every run uses identical inputs. Each precompile
  # is timed on its most expensive ("slow") cacheable input.
  var work: seq[tuple[precompile: Precompiles, input: seq[byte], note: string]]
  for (precompile, file) in cases:
    let (_, slow, note) = scenarios(precompile, validInputs(file))
    work.add (precompile, slow, note)

  # Single-threaded caches (shardBits = 0, no locking) then thread-safe caches.
  runComparison(vmState, threadSafe = false, work)
  echo ""
  runComparison(vmState, threadSafe = true, work)

main()
