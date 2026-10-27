# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocksdb constructor/destructor for Aristo DB
## ============================================

{.push raises: [].}

import std/[cpuinfo, strformat], results,   ../../[aristo_blobify, aristo_desc], ./rdb_desc, ../../../opts

# ------------------------------------------------------------------------------
# Private constructor
# ------------------------------------------------------------------------------

const
  lruOverhead = 20 # Approximate LRU cache overhead per entry based on minilru sizes
  accTrafficShare = 276 # Per mille of rdb cache lookups hitting the account trie

type TrieSplit = tuple[acc, sto: int]

func unsplitSize(V: typedesc, budget: int): int =
  budget div (sizeof(RootedVertexID) + sizeof(V) + lruOverhead)

func splitBytes(V: typedesc, split: TrieSplit, shards: int): int =
  ConcurrentLruCache[VertexID, V].realBytes(split.acc, shards) +
    ConcurrentLruCache[RootedVertexID, V].realBytes(split.sto, shards)

func shareDist(split: TrieSplit): float =
  abs(split.acc.float / float(split.acc + split.sto) - accTrafficShare.float / 1000)

func trafficSplit(V: typedesc, unsplit, shards: int): TrieSplit =
  ## Split closest to `accTrafficShare` holding no fewer entries in no more real
  ## memory than the unsplit cache - memory left over by the storage part only
  ## grows the account part within its tables
  type
    AccLru = ConcurrentLruCache[VertexID, V]
    StoLru = ConcurrentLruCache[RootedVertexID, V]
  result = (0, unsplit)
  if unsplit > 0:
    let target = StoLru.realBytes(unsplit, shards)
    var bestDist = accTrafficShare.float / 1000
    for step in 1 .. 240:
      let
        accFit = AccLru.capacityForBytes(target div 400 * step, shards)
        sto = StoLru.capacityForBytes(target - AccLru.realBytes(accFit, shards), shards)
        acc = min(
          AccLru.tableCapacity(accFit, shards),
          AccLru.capacityForBytes(target - StoLru.realBytes(sto, shards), shards),
        )
        split = (acc, sto)
      if acc + sto >= unsplit and (
        split.shareDist < bestDist or
        (split.shareDist == bestDist and acc + sto > result.acc + result.sto)
      ):
        result = split
        bestDist = split.shareDist

func compactSplit(V: typedesc, unsplit, shards: int): TrieSplit =
  ## Split holding as many entries as the unsplit cache in the least real
  ## memory, with the account part at most half of the entries
  result = (0, unsplit)
  var
    bestBytes = V.splitBytes(result, shards)
    capacity = shards
  while true:
    let full = ConcurrentLruCache[RootedVertexID, V].tableCapacity(capacity, shards)
    for split in [
      (min(full, unsplit div 2), unsplit - min(full, unsplit div 2)),
      (unsplit - min(full, unsplit), min(full, unsplit)),
    ]:
      if split[0] <= split[1] and V.splitBytes(split, shards) < bestBytes:
        result = split
        bestBytes = V.splitBytes(split, shards)
    if full >= unsplit:
      break
    capacity = full + shards

func largestSplit(V: typedesc, unsplit, budget, shards: int): TrieSplit =
  ## Split holding the most entries in `budget` bytes with the account part at
  ## most half of the entries - ties go to the one closest to `accTrafficShare`
  type
    AccLru = ConcurrentLruCache[VertexID, V]
    StoLru = ConcurrentLruCache[RootedVertexID, V]
  result = (0, unsplit)
  var bestDist = accTrafficShare.float / 1000
  for step in 1 .. 200:
    let
      accFit = AccLru.capacityForBytes(budget div 400 * step, shards)
      sto = StoLru.capacityForBytes(budget - AccLru.realBytes(accFit, shards), shards)
      acc = min(sto, AccLru.capacityForBytes(budget - StoLru.realBytes(sto, shards), shards))
      split = (acc, sto)
      total = acc + sto
    if total > result.acc + result.sto or
        (total == result.acc + result.sto and split.shareDist < bestDist):
      result = split
      bestDist = split.shareDist

proc initLrus(rdb: var RdbInst, opts: DbOptions) =
  ## The three caches together use the real memory their budgets would get
  ## unsplit - key and vertex caches shrink to their unsplit entry count when
  ## that leaves the branch cache more entries
  type BranchVal = typeof(rdb.rdBranchLru).V
  let
    threadSafe = opts.threadSafeCaches
    shards = if threadSafe: 1 shl defaultShardBits(countProcessors()) else: 1
    keyUnsplit = HashKey.unsplitSize(opts.rdbKeyCacheSize)
    vtxUnsplit = VertexBuf.unsplitSize(opts.rdbVtxCacheSize)
    branchUnsplit = BranchVal.unsplitSize(opts.rdbBranchCacheSize)
    target =
      HashKey.splitBytes((0, keyUnsplit), shards) +
      VertexBuf.splitBytes((0, vtxUnsplit), shards) +
      BranchVal.splitBytes((0, branchUnsplit), shards)
  var
    best: tuple[key, vtx, branch: TrieSplit]
    bestScore = (-1, -1)
  for keySplit in [
    HashKey.trafficSplit(keyUnsplit, shards), HashKey.compactSplit(keyUnsplit, shards)
  ]:
    for vtxSplit in [
      VertexBuf.trafficSplit(vtxUnsplit, shards),
      VertexBuf.compactSplit(vtxUnsplit, shards),
    ]:
      let
        budget =
          target - HashKey.splitBytes(keySplit, shards) -
          VertexBuf.splitBytes(vtxSplit, shards)
        branchSplit = BranchVal.largestSplit(branchUnsplit, budget, shards)
        score = (
          branchSplit.acc + branchSplit.sto,
          keySplit.acc + keySplit.sto + vtxSplit.acc + vtxSplit.sto,
        )
      if score > bestScore:
        best = (keySplit, vtxSplit, branchSplit)
        bestScore = score
  rdb.rdKeyLru.init(best.key.acc, best.key.sto, threadSafe)
  rdb.rdVtxLru.init(best.vtx.acc, best.vtx.sto, threadSafe)
  rdb.rdBranchLru.init(best.branch.acc, best.branch.sto, threadSafe)

proc dumpCacheStats(keySize, vtxSize, branchSize: tuple[acc, sto: int]) =
  block vtx:
    var misses, hits: uint64
    echo "vtxLru(World=", vtxSize.acc, " Account=", vtxSize.sto, ")"
    echo "   state    vtype       miss        hit      total hitrate"
    for state in RdbStateType:
      for vtype in RdbVertexType:
        let
          (miss, hit) = (
            rdbVtxLruStats[state][vtype].get(false),
            rdbVtxLruStats[state][vtype].get(true),
          )
          hitRate = float64(hit * 100) / (float64(hit + miss))
        misses += miss
        hits += hit
        echo &"{state:>8} {vtype:>8} {miss:>10} {hit:>10} {miss+hit:>10} {hitRate:>6.2f}%"
    let hitRate = float64(hits * 100) / (float64(hits + misses))
    echo &"     all      all {misses:>10} {hits:>10} {misses+hits:>10} {hitRate:>6.2f}%"

  block key:
    var misses, hits: uint64
    echo "keyLru(World=", keySize.acc, " Account=", keySize.sto, ")"

    echo "   state       miss        hit      total hitrate"

    for state in RdbStateType:
      let
        (miss, hit) =
          (rdbKeyLruStats[state].get(false), rdbKeyLruStats[state].get(true))
        hitRate = float64(hit * 100) / (float64(hit + miss))
      misses += miss
      hits += hit

      echo &"{state:>8} {miss:>10} {hit:>10} {miss+hit:>10} {hitRate:>5.2f}%"

    let hitRate = float64(hits * 100) / (float64(hits + misses))
    echo &"     all {misses:>10} {hits:>10} {misses+hits:>10} {hitRate:>5.2f}%"

  block key:
    var misses, hits: uint64
    echo "branchLru(World=", branchSize.acc, " Account=", branchSize.sto, ")"

    echo "   state       miss        hit      total hitrate"

    for state in RdbStateType:
      let
        (miss, hit) =
          (rdbBranchLruStats[state].get(false), rdbBranchLruStats[state].get(true))
        hitRate = float64(hit * 100) / (float64(hit + miss))
      misses += miss
      hits += hit

      echo &"{state:>8} {miss:>10} {hit:>10} {miss+hit:>10} {hitRate:>5.2f}%"

    let hitRate = float64(hits * 100) / (float64(hits + misses))
    echo &"     all {misses:>10} {hits:>10} {misses+hits:>10} {hitRate:>5.2f}%"

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(rdb: var RdbInst, opts: DbOptions, baseDb: RocksDbInstanceRef) =
  ## Database backend constructor
  rdb.baseDb = baseDb

  rdb.initLrus(opts)
  rdb.rdbPrintStats = opts.rdbPrintStats
  rdb.threadSafeCaches = opts.threadSafeCaches

  rdb.vtxCol = baseDb.db.getColFamily($VtxCF).valueOr:
    raiseAssert "Cannot initialise VtxCF descriptor: " & error

proc close*(rdb: var RdbInst, wipe: bool) =
  ## Destructor
  rdb.rdKeyLru.dispose()
  rdb.rdVtxLru.dispose()
  rdb.rdBranchLru.dispose()

  let
    ks = (rdb.rdKeyLru.accSize, rdb.rdKeyLru.stoSize)
    vs = (rdb.rdVtxLru.accSize, rdb.rdVtxLru.stoSize)
    bs = (rdb.rdBranchLru.accSize, rdb.rdBranchLru.stoSize)
  rdb.baseDb.close(wipe)
  if rdb.rdbPrintStats:
    dumpCacheStats(ks, vs, bs)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
