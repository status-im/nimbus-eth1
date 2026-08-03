# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Throughput benchmark for the BlockAccessListBuilder.
#
# The workload models a block as `numTx` transactions, each of which is a
# distinct block access index that touches a handful of accounts (with storage
# writes/reads, balance/nonce and the occasional code change). This mirrors how
# parallel block execution assigns each transaction/block-access-index to a
# single worker thread.
#
# Two scenarios are timed:
#   * single-threaded fill
#   * multi-threaded fill where N worker threads each own a disjoint range of
#     transaction indices and write into the *same* builder concurrently
# In both cases the BlockAccessList is then materialized on the main thread and
# that build step is timed separately.
#
# The benchmark is written to compile against both the lock-based builder (which
# serializes every write on an internal lock) and the lock-free index-partitioned
# builder (where each block access index is an independent single-writer
# partition), via `when compiles` guards, so the exact same workload can be run
# against both to compare them.

{.used.}

import
  std/[strformat, strutils, times],
  unittest2,
  stint,
  eth/common/addresses,
  ../../execution_chain/block_access_list/bal_builder

const
  benchNameWidth = 26
  numTx = 2048 ## transactions == distinct block access indices in the block
  accountsPerTx = 8 ## accounts touched by each transaction
  numAccounts = 4000 ## address space (accounts are shared across transactions)
  writesPerAccount = 4 ## storage writes per touched account (per transaction)
  readsPerAccount = 2 ## storage reads per touched account (per transaction)
  codeLen = 32 ## bytes of code per code change
  repeats = 10
    ## Each measured scenario builds a fresh builder and fills/builds/disposes it
    ## `repeats` times; the reported figures are averages.

type
  Stats = object
    fill: float ## average wall-clock of the fill phase (seconds)
    build: float ## average wall-clock of the build phase (seconds)
    checksum: int ## consumed so the build result is not optimized away

  FillRange = object
    builder: ptr BlockAccessListBuilder
    startTx: int
    endTx: int

func makeAddress(i: int): Address =
  var b: array[20, byte]
  for k in 0 ..< 8:
    b[19 - k] = byte((uint(i) shr (8 * k)) and 0xff)
  b.to(Address)

template presize(b: ptr BlockAccessListBuilder, n: int) =
  ## Reserve `n` block access index partitions up front. Only the lock-free
  ## builder needs (and provides) this; on the lock-based builder it is a no-op.
  when compiles(b[].ensureIndexCount(n)):
    b[].ensureIndexCount(n)

template initBuilder(b: var BlockAccessListBuilder, threadSafe: bool) =
  ## Portable init: the lock-based (master) builder takes a `threadSafe` flag and
  ## must be told to lock for concurrent writes; the lock-free builder does not
  ## take the flag (each block access index has a single writer).
  when compiles(b.init(threadSafe = threadSafe)):
    b.init(threadSafe = threadSafe)
  else:
    b.init()

proc fillTx(b: ptr BlockAccessListBuilder, txIndex: int) =
  ## Emit the changes for one transaction, all recorded at block access index
  ## `txIndex`. This is the unit of work owned by a single thread.
  for a in 0 ..< accountsPerTx:
    let
      acctId = (txIndex * 7 + a * 131) mod numAccounts
      address = makeAddress(acctId)

    when compiles(b[].addTouchedAccount(txIndex, address)):
      b[].addTouchedAccount(txIndex, address)
    else:
      b[].addTouchedAccount(address)

    for s in 0 ..< writesPerAccount:
      b[].addStorageWrite(txIndex, address, u256(acctId * 100 + s), u256(s + 1))

    for r in 0 ..< readsPerAccount:
      let slot = u256(acctId * 100 + 50 + r)
      when compiles(b[].addStorageRead(txIndex, address, slot)):
        b[].addStorageRead(txIndex, address, slot)
      else:
        b[].addStorageRead(address, slot)

    b[].addBalanceChange(txIndex, address, u256(acctId + 1))
    b[].addNonceChange(txIndex, address, AccountNonce(txIndex + 1))

    if a == 0:
      var code: array[codeLen, byte]
      for k in 0 ..< codeLen:
        code[k] = byte((acctId + k) and 0xff)
      b[].addCodeChange(txIndex, address, code)

proc fillRangeProc(ctx: ptr FillRange) {.thread.} =
  for t in ctx.startTx ..< ctx.endTx:
    fillTx(ctx.builder, t)

proc benchmarkHeader(): string =
  "  " & alignLeft("benchmark", benchNameWidth) & " " & align("fill(ms)", 10) & " " &
    align("build(ms)", 10) & " " & align("Mwrites/s", 12) & " " & align("speedup", 9)

proc benchmarkLine(name: string, s: Stats, baseline: float): string =
  # Roughly the number of builder mutations issued during the fill phase.
  const opsPerTx =
    accountsPerTx * (1 + writesPerAccount + readsPerAccount + 2) + 1 # + one code change
  let
    writesPerSec = (numTx * opsPerTx).float / s.fill
    speedup = baseline / s.fill
  "  " & alignLeft(name, benchNameWidth) & " " & align(fmt"{s.fill * 1000:.2f}", 10) &
    " " & align(fmt"{s.build * 1000:.2f}", 10) & " " &
    align(fmt"{writesPerSec / 1e6:.2f}", 12) & " " & align(fmt"{speedup:.2f}x", 9)

proc benchSingle(): Stats =
  var fillTotal, buildTotal = 0.0
  var checksum = 0
  for r in 0 ..< repeats:
    var builder: BlockAccessListBuilder
    initBuilder(builder, false)
    let b = addr builder
    b.presize(numTx)

    let t0 = epochTime()
    for t in 0 ..< numTx:
      fillTx(b, t)
    fillTotal += epochTime() - t0

    let t1 = epochTime()
    let bal = builder.buildBlockAccessList()
    buildTotal += epochTime() - t1
    checksum += bal[].len()

    builder.dispose()
  Stats(fill: fillTotal / repeats.float, build: buildTotal / repeats.float, checksum: checksum)

proc benchThreaded(nThreads: static int): Stats =
  let chunk = numTx div nThreads
  var fillTotal, buildTotal = 0.0
  var checksum = 0
  for r in 0 ..< repeats:
    var builder: BlockAccessListBuilder
    initBuilder(builder, true)
    let b = addr builder
    # Pre-size on the main thread before spawning so that the workers only append
    # into already-allocated partitions (lock-free builder). No-op on the locked
    # builder.
    b.presize(numTx)

    var
      threads: array[nThreads, Thread[ptr FillRange]]
      ranges: array[nThreads, FillRange]
    for t in 0 ..< nThreads:
      let startTx = t * chunk
      let endTx = if t == nThreads - 1: numTx else: startTx + chunk
      ranges[t] = FillRange(builder: b, startTx: startTx, endTx: endTx)

    let t0 = epochTime()
    for t in 0 ..< nThreads:
      createThread(threads[t], fillRangeProc, addr ranges[t])
    for t in 0 ..< nThreads:
      joinThread(threads[t])
    fillTotal += epochTime() - t0

    let t1 = epochTime()
    let bal = builder.buildBlockAccessList()
    buildTotal += epochTime() - t1
    checksum += bal[].len()

    builder.dispose()
  Stats(fill: fillTotal / repeats.float, build: buildTotal / repeats.float, checksum: checksum)

suite "BlockAccessListBuilder throughput benchmark":
  test "Single-threaded fill + build":
    let s = benchSingle()
    debugEcho ""
    debugEcho "  builder: ",
      when compiles((var x: BlockAccessListBuilder; x.ensureIndexCount(1))):
        "lock-free (index-partitioned)"
      else:
        "lock-based (shared)"
    debugEcho "  txs=", numTx, ", accounts/tx=", accountsPerTx, ", writes/acct=",
      writesPerAccount, ", reads/acct=", readsPerAccount, ", repeats=", repeats
    debugEcho benchmarkHeader()
    debugEcho benchmarkLine("single-threaded", s, s.fill)
    check s.checksum > 0

  test "Multi-threaded fill + build (tx-index partitioned)":
    let
      s1 = benchThreaded(1)
      s2 = benchThreaded(2)
      s4 = benchThreaded(4)
      s8 = benchThreaded(8)
      s16 = benchThreaded(16)

    debugEcho ""
    debugEcho "  N threads each own a disjoint range of the ", numTx,
      " transaction indices; build runs on the main thread"
    debugEcho benchmarkHeader()
    let base = s1.fill
    debugEcho benchmarkLine("1-thread", s1, base)
    debugEcho benchmarkLine("2-thread", s2, base)
    debugEcho benchmarkLine("4-thread", s4, base)
    debugEcho benchmarkLine("8-thread", s8, base)
    debugEcho benchmarkLine("16-thread", s16, base)

    # All thread counts must materialize the exact same set of accounts.
    check:
      s1.checksum == s2.checksum
      s1.checksum == s4.checksum
      s1.checksum == s8.checksum
      s1.checksum == s16.checksum
