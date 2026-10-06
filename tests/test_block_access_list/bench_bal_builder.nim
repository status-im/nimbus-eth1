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
# Each scenario models a block as `numTx` transactions, each of which is a
# distinct block access index that touches some accounts (with storage
# writes/reads, balance/nonce and possibly code changes). This mirrors how
# parallel block execution assigns each transaction/block-access-index to a
# single worker thread. The scenarios range from plain transfers to blocks that
# hammer a single hot contract or create thousands of fresh accounts, so that
# every part of the builder (fill, grouping, sorting, emitting) gets exercised.
#
# For every scenario two things are timed:
#   * single-threaded fill
#   * multi-threaded fill where N worker threads each own a disjoint range of
#     transaction indices and write into the *same* builder concurrently
# In both cases the BlockAccessList is then materialized on the main thread and
# that build step is timed separately, along with the end-to-end time from the
# start of the fill to the end of the build which is what a block pays overall.
# The "reused" rows keep one builder across the repeats and `clear` it between
# blocks, which is how the node runs it in steady state; the other rows build a
# fresh builder per block.
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

type
  Workload = object
    name: string
    numTx: int ## transactions == distinct block access indices in the block
    numAccounts: int ## address space (accounts are shared across transactions)
    accountsPerTx: int ## accounts touched by each transaction
    storageAccounts: int ## how many of the touched accounts get storage access
    writesPerAccount: int ## storage writes per storage account (per transaction)
    readsPerAccount: int ## storage reads per storage account (per transaction)
    nonceAccounts: int ## how many of the touched accounts get a nonce change
    codeLen: int ## bytes of code set on the first touched account, 0 for none

const
  benchNameWidth = 16
  repeats = 10
    ## Each measured scenario builds a fresh builder and fills/builds/disposes it
    ## `repeats` times; the reported figures are averages.
  maxCodeLen = 4096

  scenarios = [
    # A contract-heavy transaction: many touched accounts, each with several
    # storage writes and reads, plus a code change.
    Workload(
      name: "heavy tx",
      numTx: 2048,
      numAccounts: 4000,
      accountsPerTx: 8,
      storageAccounts: 8,
      writesPerAccount: 4,
      readsPerAccount: 2,
      nonceAccounts: 8,
      codeLen: 32,
    ),
    # A plain transfer: sender, recipient and coinbase are touched and have
    # their balance changed, only the sender's nonce changes, and there is no
    # storage access or code change.
    Workload(
      name: "plain transfer",
      numTx: 2048,
      numAccounts: 4000,
      accountsPerTx: 3,
      storageAccounts: 0,
      writesPerAccount: 0,
      readsPerAccount: 0,
      nonceAccounts: 1,
      codeLen: 0,
    ),
    # An ERC-20 transfer: sender, token contract and coinbase, with the two
    # balance slots written and the allowance/balance read on the contract.
    Workload(
      name: "erc20 transfer",
      numTx: 2048,
      numAccounts: 4000,
      accountsPerTx: 3,
      storageAccounts: 1,
      writesPerAccount: 2,
      readsPerAccount: 1,
      nonceAccounts: 1,
      codeLen: 0,
    ),
    # A read-heavy contract call touching several contracts that mostly read.
    Workload(
      name: "read heavy call",
      numTx: 2048,
      numAccounts: 4000,
      accountsPerTx: 6,
      storageAccounts: 4,
      writesPerAccount: 1,
      readsPerAccount: 12,
      nonceAccounts: 1,
      codeLen: 0,
    ),
    # Every transaction hits the same handful of contracts, so each account
    # accumulates thousands of storage entries that must be grouped and sorted.
    Workload(
      name: "hot contract",
      numTx: 2048,
      numAccounts: 16,
      accountsPerTx: 4,
      storageAccounts: 2,
      writesPerAccount: 8,
      readsPerAccount: 8,
      nonceAccounts: 1,
      codeLen: 0,
    ),
    # An airdrop-like block where nearly every touched account is distinct.
    Workload(
      name: "fresh accounts",
      numTx: 2048,
      numAccounts: 1_000_000,
      accountsPerTx: 4,
      storageAccounts: 1,
      writesPerAccount: 1,
      readsPerAccount: 0,
      nonceAccounts: 1,
      codeLen: 0,
    ),
    # Contract deployments: a large code change plus constructor storage.
    Workload(
      name: "contract deploy",
      numTx: 2048,
      numAccounts: 4000,
      accountsPerTx: 2,
      storageAccounts: 1,
      writesPerAccount: 3,
      readsPerAccount: 0,
      nonceAccounts: 1,
      codeLen: maxCodeLen,
    ),
    # A very large block of plain transfers over a wide address space.
    Workload(
      name: "large block",
      numTx: 16384,
      numAccounts: 50_000,
      accountsPerTx: 3,
      storageAccounts: 0,
      writesPerAccount: 0,
      readsPerAccount: 0,
      nonceAccounts: 1,
      codeLen: 0,
    ),
  ]

  codePattern = block:
    var a: array[maxCodeLen, byte]
    for k in 0 ..< maxCodeLen:
      a[k] = byte(k and 0xff)
    a

type
  Stats = object
    fill: float ## average wall-clock of the fill phase (seconds)
    build: float ## average wall-clock of the build phase (seconds)
    total: float ## average wall-clock from fill start to build end (seconds)
    checksum: int ## consumed so the build result is not optimized away

  FillRange = object
    builder: ptr BlockAccessListBuilder
    workload: Workload
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

proc fillTx(b: ptr BlockAccessListBuilder, w: Workload, txIndex: int) =
  ## Emit the changes for one transaction, all recorded at block access index
  ## `txIndex`. This is the unit of work owned by a single thread.
  for a in 0 ..< w.accountsPerTx:
    let
      acctId = (txIndex * 7 + a * 131) mod w.numAccounts
      address = makeAddress(acctId)

    when compiles(b[].addTouchedAccount(txIndex, address)):
      b[].addTouchedAccount(txIndex, address)
    else:
      b[].addTouchedAccount(address)

    if a < w.storageAccounts:
      for s in 0 ..< w.writesPerAccount:
        b[].addStorageWrite(txIndex, address, u256(acctId * 100 + s), u256(s + 1))

      for r in 0 ..< w.readsPerAccount:
        let slot = u256(acctId * 100 + 50 + r)
        when compiles(b[].addStorageRead(txIndex, address, slot)):
          b[].addStorageRead(txIndex, address, slot)
        else:
          b[].addStorageRead(address, slot)

    b[].addBalanceChange(txIndex, address, u256(acctId + 1))
    if a < w.nonceAccounts:
      b[].addNonceChange(txIndex, address, AccountNonce(txIndex + 1))

    if a == 0 and w.codeLen > 0:
      b[].addCodeChange(txIndex, address, codePattern.toOpenArray(0, w.codeLen - 1))

proc fillRangeProc(ctx: ptr FillRange) {.thread.} =
  for t in ctx.startTx ..< ctx.endTx:
    fillTx(ctx.builder, ctx.workload, t)

proc benchmarkHeader(): string =
  "  " & alignLeft("benchmark", benchNameWidth) & " " & align("fill(ms)", 10) & " " &
    align("build(ms)", 10) & " " & align("total(ms)", 10) & " " & align("Mwrites/s", 12) &
    " " & align("speedup", 9)

proc benchmarkLine(name: string, w: Workload, s: Stats, baseline: float): string =
  # Roughly the number of builder mutations issued during the fill phase.
  # The speedup is that of the end-to-end time relative to `baseline`.
  let
    opsPerTx =
      w.accountsPerTx * 2 +
      w.storageAccounts * (w.writesPerAccount + w.readsPerAccount) + w.nonceAccounts +
      (if w.codeLen > 0: 1 else: 0)
    writesPerSec = (w.numTx * opsPerTx).float / s.fill
    speedup = baseline / s.total
  "  " & alignLeft(name, benchNameWidth) & " " & align(fmt"{s.fill * 1000:.2f}", 10) &
    " " & align(fmt"{s.build * 1000:.2f}", 10) & " " & align(fmt"{s.total * 1000:.2f}", 10) &
    " " & align(fmt"{writesPerSec / 1e6:.2f}", 12) & " " & align(fmt"{speedup:.2f}x", 9)

template withBuilder(reuse: bool, threadSafe: bool, builder, body: untyped) =
  ## Run `body` once per repeat with `builder` either freshly created for each
  ## repeat, or created once, warmed up with one untimed repeat and cleared in
  ## between.
  if reuse:
    var shared: BlockAccessListBuilder
    initBuilder(shared, threadSafe)
    for r {.inject.} in 0 .. repeats:
      template builder(): untyped =
        shared

      body
      shared.clear()
    shared.dispose()
  else:
    for r {.inject.} in 0 ..< repeats:
      var fresh: BlockAccessListBuilder
      initBuilder(fresh, threadSafe)
      template builder(): untyped =
        fresh

      body
      fresh.dispose()

template timed(
    stats: var tuple[fill, build, all: float], r: int, fillBody, buildBody: untyped
) =
  ## Time `fillBody` and `buildBody`, skipping the warm-up repeat of a reused
  ## builder (`r == repeats`, the extra one) in the totals.
  let t0 = epochTime()
  fillBody
  let t1 = epochTime()
  buildBody
  let t2 = epochTime()
  if r < repeats:
    stats.fill += t1 - t0
    stats.build += t2 - t1
    stats.all += t2 - t0

proc benchSingle(w: Workload, reuse = false): Stats =
  var totals: tuple[fill, build, all: float]
  var checksum = 0
  withBuilder(reuse, false, builder):
    let b = addr builder
    b.presize(w.numTx)
    totals.timed(r):
      for t in 0 ..< w.numTx:
        fillTx(b, w, t)
    do:
      let bal = builder.buildBlockAccessList()
      if r < repeats:
        checksum += bal[].len()
  Stats(
    fill: totals.fill / repeats.float,
    build: totals.build / repeats.float,
    total: totals.all / repeats.float,
    checksum: checksum,
  )

proc benchThreaded(nThreads: static int, w: Workload, reuse = false): Stats =
  let chunk = w.numTx div nThreads
  var totals: tuple[fill, build, all: float]
  var checksum = 0
  withBuilder(reuse, true, builder):
    let b = addr builder
    # Pre-size on the main thread before spawning so that the workers only append
    # into already-allocated partitions (lock-free builder). No-op on the locked
    # builder.
    b.presize(w.numTx)

    var
      threads: array[nThreads, Thread[ptr FillRange]]
      ranges: array[nThreads, FillRange]
    for t in 0 ..< nThreads:
      let startTx = t * chunk
      let endTx = if t == nThreads - 1: w.numTx else: startTx + chunk
      ranges[t] = FillRange(builder: b, workload: w, startTx: startTx, endTx: endTx)

    totals.timed(r):
      for t in 0 ..< nThreads:
        createThread(threads[t], fillRangeProc, addr ranges[t])
      for t in 0 ..< nThreads:
        joinThread(threads[t])
    do:
      let bal = builder.buildBlockAccessList()
      if r < repeats:
        checksum += bal[].len()
  Stats(
    fill: totals.fill / repeats.float,
    build: totals.build / repeats.float,
    total: totals.all / repeats.float,
    checksum: checksum,
  )

proc describe(w: Workload): string =
  "txs=" & $w.numTx & ", address space=" & $w.numAccounts & ", accounts/tx=" &
    $w.accountsPerTx & ", storage accounts=" & $w.storageAccounts & ", writes/acct=" &
    $w.writesPerAccount & ", reads/acct=" & $w.readsPerAccount & ", nonces=" &
    $w.nonceAccounts & ", code bytes=" & $w.codeLen & ", repeats=" & $repeats

proc runSingle(w: Workload) =
  let
    s = benchSingle(w)
    reused = benchSingle(w, reuse = true)
  debugEcho ""
  debugEcho "  ", w.name, ": ", w.describe()
  debugEcho benchmarkHeader()
  debugEcho benchmarkLine("single-threaded", w, s, s.total)
  debugEcho benchmarkLine("single reused", w, reused, s.total)
  check:
    s.checksum > 0
    s.checksum == reused.checksum

proc runThreaded(w: Workload) =
  let
    s1 = benchThreaded(1, w)
    s2 = benchThreaded(2, w)
    s4 = benchThreaded(4, w)
    s8 = benchThreaded(8, w)
    s16 = benchThreaded(16, w)
    s4reused = benchThreaded(4, w, reuse = true)

  debugEcho ""
  debugEcho "  ", w.name, ": ", w.describe()
  debugEcho "  N threads each own a disjoint range of the ", w.numTx,
    " transaction indices; build runs on the main thread; speedup is end-to-end"
  debugEcho benchmarkHeader()
  let base = s1.total
  debugEcho benchmarkLine("1-thread", w, s1, base)
  debugEcho benchmarkLine("2-thread", w, s2, base)
  debugEcho benchmarkLine("4-thread", w, s4, base)
  debugEcho benchmarkLine("8-thread", w, s8, base)
  debugEcho benchmarkLine("16-thread", w, s16, base)
  debugEcho benchmarkLine("4-thread reused", w, s4reused, base)

  # All thread counts must materialize the exact same set of accounts.
  check:
    s1.checksum == s2.checksum
    s1.checksum == s4.checksum
    s1.checksum == s8.checksum
    s1.checksum == s16.checksum
    s1.checksum == s4reused.checksum

suite "BlockAccessListBuilder throughput benchmark":
  debugEcho ""
  debugEcho "  builder: ",
    when compiles((var x: BlockAccessListBuilder; x.ensureIndexCount(1))):
      "lock-free (index-partitioned)"
    else:
      "lock-based (shared)"

  for w in scenarios:
    test w.name & ": single-threaded fill + build":
      runSingle(w)

  for w in scenarios:
    test w.name & ": multi-threaded fill + build (tx-index partitioned)":
      runThreaded(w)
