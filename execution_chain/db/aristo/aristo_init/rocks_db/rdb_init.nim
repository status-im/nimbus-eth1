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

import std/strformat, results,   ../../[aristo_blobify, aristo_desc], ./rdb_desc, ../../../opts

# ------------------------------------------------------------------------------
# Private constructor
# ------------------------------------------------------------------------------

const lruOverhead = 20 # Approximate LRU cache overhead per entry based on minilru sizes

template capacity(K, V: typedesc, budget: int): int =
  budget div (sizeof(K) + sizeof(V) + lruOverhead)

proc initLru[A, S](lru: var RdbTrieLru[A, S], accBudget, stoBudget: int, threadSafe: bool) =
  lru.init(
    capacity(VertexID, A, accBudget), capacity(RootedVertexID, S, stoBudget), threadSafe
  )

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

  rdb.rdKeyLru.initLru(
    opts.rdbAccKeyCacheSize, opts.rdbStoKeyCacheSize, opts.threadSafeCaches)
  rdb.rdVtxLru.initLru(
    opts.rdbAccVtxCacheSize, opts.rdbStoVtxCacheSize, opts.threadSafeCaches)
  rdb.rdBranchLru.initLru(
    opts.rdbAccBranchCacheSize, opts.rdbStoBranchCacheSize, opts.threadSafeCaches)
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
    ks = (rdb.rdKeyLru.accCapacity, rdb.rdKeyLru.stoCapacity)
    vs = (rdb.rdVtxLru.accCapacity, rdb.rdVtxLru.stoCapacity)
    bs = (rdb.rdBranchLru.accCapacity, rdb.rdBranchLru.stoCapacity)
  rdb.baseDb.close(wipe)
  if rdb.rdbPrintStats:
    dumpCacheStats(ks, vs, bs)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
