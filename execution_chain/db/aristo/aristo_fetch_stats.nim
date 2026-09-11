# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Lookup counters for account and storage slot fetches, reported when the
## database is closed. Disable with `-d:noLeafFetchStats`.

{.push raises: [].}

import std/[strutils, concurrency/atomics], chronicles

const
  LeafFetchStats* = not defined(noLeafFetchStats)
    ## Count the trie lookups that each leaf fetch needs, disabled with
    ## `-d:noLeafFetchStats`

  MaxStatThreads = 64
  Buckets = 12

type
  FetchCounters = object
    fetches: uint64
    vtxLookups: uint64
    beLookups: uint64
    dbGets: uint64
    accGets: uint64
    hist: array[Buckets, uint64]

  ThreadCounters* = object
    vtx*, be*, db*: uint64
    acc, sto: FetchCounters
    padding: array[24, byte]

  FetchMark* = tuple[vtx, be, db: uint64]

var
  statSlots: array[MaxStatThreads, ThreadCounters]
  statSlotsUsed: Atomic[int]

when compileOption("threads"):
  var statSlot {.threadvar.}: int
else:
  var statSlot: int

proc fetchCounters*(): ptr ThreadCounters =
  ## Counters of the calling thread, claimed on first use
  if statSlot == 0:
    statSlot = 1 + min(statSlotsUsed.fetchAdd(1, moRelaxed), MaxStatThreads - 1)
  addr statSlots[statSlot - 1]

template countVtxLookup*() =
  when LeafFetchStats:
    fetchCounters().vtx += 1
  else:
    discard

template countBackendLookup*() =
  when LeafFetchStats:
    fetchCounters().be += 1
  else:
    discard

template countDbGet*() =
  when LeafFetchStats:
    fetchCounters().db += 1
  else:
    discard

proc mark*(c: ptr ThreadCounters): FetchMark =
  (c.vtx, c.be, c.db)

proc record(f: var FetchCounters, c: ptr ThreadCounters, m: FetchMark) =
  let gets = c.db - m.db
  f.fetches += 1
  f.vtxLookups += c.vtx - m.vtx
  f.beLookups += c.be - m.be
  f.dbGets += gets
  f.hist[int min(gets, uint64(Buckets - 1))] += 1

proc recordAccFetch*(c: ptr ThreadCounters, m: FetchMark) =
  c.acc.record(c, m)

proc recordSlotFetch*(c: ptr ThreadCounters, m: FetchMark) =
  c.sto.record(c, m)

proc recordSlotAccLookup*(c: ptr ThreadCounters, m: FetchMark) =
  ## Queries a slot fetch spent resolving its account leaf
  c.sto.accGets += c.db - m.db

proc sum(dst: var FetchCounters, src: FetchCounters) =
  dst.fetches += src.fetches
  dst.vtxLookups += src.vtxLookups
  dst.beLookups += src.beLookups
  dst.dbGets += src.dbGets
  dst.accGets += src.accGets
  for i in 0 ..< Buckets:
    dst.hist[i] += src.hist[i]

proc ratio(a, b: uint64): string =
  formatFloat(a.float / b.float, ffDecimal, 2)

proc percent(a, b: uint64): string =
  formatFloat(100.0 * a.float / b.float, ffDecimal, 1) & "%"

proc histogram(f: FetchCounters): string =
  for i in 0 ..< Buckets:
    if 0 < f.hist[i]:
      if 0 < result.len:
        result.add " "
      result.add (if i == Buckets - 1: $i & "+" else: $i)
      result.add ":" & percent(f.hist[i], f.fetches)

proc report(f: FetchCounters, leaf: string, withAccLookup: bool) =
  if f.fetches == 0:
    return
  let
    queried = f.fetches - f.hist[0]
    accLookups = if withAccLookup: ratio(f.accGets, f.fetches) else: "n/a"
  notice "Leaf fetch lookups",
    leaf,
    fetches = f.fetches,
    dbGets = f.dbGets,
    vertexLookups = f.vtxLookups,
    servedWithoutDbGet = percent(f.hist[0], f.fetches),
    dbGetsPerFetch = ratio(f.dbGets, f.fetches),
    dbGetsWhenQueried = (if 0 < queried: ratio(f.dbGets, queried) else: "n/a"),
    accountLookupGets = accLookups,
    vertexLookupsPerFetch = ratio(f.vtxLookups, f.fetches),
    backendLookupsPerFetch = ratio(f.beLookups, f.fetches),
    dbGetsHistogram = f.histogram()

proc logLeafFetchStats*() =
  ## Report and reset the lookup counters of all threads
  when LeafFetchStats:
    var acc, sto: FetchCounters
    for i in 0 ..< min(statSlotsUsed.load(moRelaxed), MaxStatThreads):
      acc.sum(statSlots[i].acc)
      sto.sum(statSlots[i].sto)
      statSlots[i].acc.reset()
      statSlots[i].sto.reset()
    acc.report("account", false)
    sto.report("slot", true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
