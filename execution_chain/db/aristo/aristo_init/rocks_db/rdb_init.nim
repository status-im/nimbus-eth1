# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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

import std/[exitprocs, strformat], results, ../../aristo_desc, ./rdb_desc, ../../../opts

# ------------------------------------------------------------------------------
# Private constructor
# ------------------------------------------------------------------------------

const lruOverhead = 20 # Approximate LRU cache overhead per entry based on minilru sizes

proc dumpCacheStats(keySize, vtxSize, branchSize: int) =
  block vtx:
    var misses, hits: uint64
    echo "vtxLru(", vtxSize, ")"
    echo "   state    vtype       miss        hit      total hitrate"
    for state in RdbStateType:
      for vtype in VertexType:
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
    echo "keyLru(", keySize, ") "

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
    echo "branchLru(", branchSize, ") "

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

  # bytes -> entries based on overhead estimates
  rdb.rdKeySize =
    opts.rdbKeyCacheSize div (sizeof(VertexID) + sizeof(HashKey) + lruOverhead)
  rdb.rdVtxSize =
    opts.rdbVtxCacheSize div
    (sizeof(VertexID) + sizeof(default(VertexRef)[]) + lruOverhead)

  rdb.rdBranchSize =
    opts.rdbBranchCacheSize div (sizeof(typeof(rdb.rdBranchLru).V) + lruOverhead)

  rdb.rdKeyLru = typeof(rdb.rdKeyLru).init(rdb.rdKeySize)
  rdb.rdVtxLru = typeof(rdb.rdVtxLru).init(rdb.rdVtxSize)
  rdb.rdBranchLru = typeof(rdb.rdBranchLru).init(rdb.rdBranchSize)

  if opts.rdbPrintStats:
    let
      ks = rdb.rdKeySize
      vs = rdb.rdVtxSize
      bs = rdb.rdBranchSize
    # TODO instead of dumping at exit, these stats could be logged or written
    #      to a file for better tracking over time - that said, this is mainly
    #      a debug utility at this point
    addExitProc(
      proc() =
        dumpCacheStats(ks, vs, bs)
    )

  # Initialise column handlers (this stores implicitely `baseDb`)
  rdb.admCol = baseDb.db.getColFamily($AdmCF).valueOr:
    raiseAssert "Cannot initialise AdmCF descriptor: " & error
  rdb.vtxCol = baseDb.db.getColFamily($VtxCF).valueOr:
    raiseAssert "Cannot initialise VtxCF descriptor: " & error

proc destroy*(rdb: var RdbInst, eradicate: bool) =
  ## Destructor
  rdb.baseDb.close(eradicate)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
