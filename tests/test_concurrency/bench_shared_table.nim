# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import
  std/[strformat, strutils, tables, times],
  unittest2,
  ../../execution_chain/concurrency/shared_types

const
  benchNameWidth = 36
  tableSize = 100_000
  ops = 8_000_000

type BenchmarkStats = object
  elapsed: float
  operations: int
  checksum: uint64

proc benchmarkHeader(): string =
  "  " & alignLeft("benchmark", benchNameWidth) & " " & align("elapsed(s)", 10) & " " &
    align("ops/s", 14) & " " & align("ns/op", 10)

proc benchmarkLine(name: string, stats: BenchmarkStats): string =
  let
    opsPerSec = stats.operations.float / stats.elapsed
    nsPerOp = (stats.elapsed * 1_000_000_000.0) / stats.operations.float
  "  " & alignLeft(name, benchNameWidth) & " " & align(fmt"{stats.elapsed:.4f}", 10) &
    " " & align(fmt"{opsPerSec:.0f}", 14) & " " & align(fmt"{nsPerOp:.1f}", 10)

# --- std/tables.Table ---

proc runStdPut(t: var Table[int, int], count: int): BenchmarkStats =
  let started = epochTime()
  for i in 0 ..< count:
    t[i mod tableSize] = i
  BenchmarkStats(elapsed: epochTime() - started, operations: count)

proc runStdGet(t: var Table[int, int], count: int): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    t.withValue(i mod tableSize, v):
      checksum += uint64(v[]) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runStdContains(t: var Table[int, int], count: int): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    if (i mod tableSize) in t:
      checksum += 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runStdDel(t: var Table[int, int], count: int): BenchmarkStats =
  # Delete then re-insert so the table population stays roughly constant.
  let started = epochTime()
  for i in 0 ..< count:
    let key = i mod tableSize
    t.del(key)
    t[key] = i
  BenchmarkStats(elapsed: epochTime() - started, operations: count)

# --- SharedTable ---

proc runSharedPut(t: var SharedTable[int, int], count: int): BenchmarkStats =
  let started = epochTime()
  for i in 0 ..< count:
    t.put(i mod tableSize, i)
  BenchmarkStats(elapsed: epochTime() - started, operations: count)

proc runSharedGet(t: var SharedTable[int, int], count: int): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    let v = t.get(i mod tableSize)
    if v.isSome():
      checksum += uint64(v.unsafeGet()) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runSharedWithValue(t: var SharedTable[int, int], count: int): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    t.withValue(i mod tableSize, v):
      checksum += uint64(v[]) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runSharedContains(t: var SharedTable[int, int], count: int): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    if t.contains(i mod tableSize):
      checksum += 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runSharedDel(t: var SharedTable[int, int], count: int): BenchmarkStats =
  let started = epochTime()
  for i in 0 ..< count:
    let key = i mod tableSize
    discard t.del(key)
    t.put(key, i)
  BenchmarkStats(elapsed: epochTime() - started, operations: count)

proc refillStd(t: var Table[int, int]) =
  t.clear()
  for i in 0 ..< tableSize:
    t[i] = i + 1 # value = key+1 so key 0 also has a non-zero value

proc refillShared(t: var SharedTable[int, int]) =
  t.clear()
  for i in 0 ..< tableSize:
    t.put(i, i + 1)

suite "SharedTable vs std/tables.Table comparison":
  test "Single-threaded throughput comparison":
    var std = initTable[int, int](tableSize)
    var shared = SharedTable[int, int].init(tableSize)
    defer:
      shared.dispose()

    # Measure put on a populated table (updates / steady state).
    refillStd(std)
    refillShared(shared)
    let
      stdPut = runStdPut(std, ops)
      sharedPut = runSharedPut(shared, ops)

    refillStd(std)
    refillShared(shared)
    let
      stdGet = runStdGet(std, ops)
      sharedGet = runSharedGet(shared, ops)
      sharedWithValue = runSharedWithValue(shared, ops)
      stdContains = runStdContains(std, ops)
      sharedContains = runSharedContains(shared, ops)
      stdDel = runStdDel(std, ops)
      sharedDel = runSharedDel(shared, ops)

    debugEcho ""
    debugEcho "  size=", tableSize, ", ops=", ops
    debugEcho benchmarkHeader()
    debugEcho benchmarkLine("Table put", stdPut)
    debugEcho benchmarkLine("SharedTable put", sharedPut)
    debugEcho benchmarkLine("Table get (withValue)", stdGet)
    debugEcho benchmarkLine("SharedTable get (Opt copy)", sharedGet)
    debugEcho benchmarkLine("SharedTable get (withValue)", sharedWithValue)
    debugEcho benchmarkLine("Table contains", stdContains)
    debugEcho benchmarkLine("SharedTable contains", sharedContains)
    debugEcho benchmarkLine("Table del+reinsert", stdDel)
    debugEcho benchmarkLine("SharedTable del+reinsert", sharedDel)

    check:
      stdPut.elapsed > 0
      sharedPut.elapsed > 0
      stdGet.checksum != 0
      sharedGet.checksum != 0
      stdGet.checksum == sharedGet.checksum
      stdContains.checksum == sharedContains.checksum
      stdDel.elapsed > 0
      sharedDel.elapsed > 0
