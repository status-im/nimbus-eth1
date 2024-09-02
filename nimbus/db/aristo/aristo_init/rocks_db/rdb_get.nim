# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB fetch data record
## ==========================

{.push raises: [].}

import
  eth/common,
  rocksdb,
  results,
  stew/keyed_queue,
  ../../[aristo_blobify, aristo_desc],
  ../init_common,
  ./rdb_desc,
  metrics,
  std/concurrency/atomics

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import
    chronicles

  logScope:
    topics = "aristo-rocksdb"

type
  RdbVtxLruCounter = ref object of Counter
  RdbKeyLruCounter = ref object of Counter

  LruCounter = array[bool, Atomic[uint64]]

  StateType = enum
    Account
    World

var
  # Hit/miss counters for LRU cache - global so as to integrate easily with
  # nim-metrics and `uint64` to ensure that increasing them is fast - collection
  # happens from a separate thread.
  # TODO maybe turn this into more general framework for LRU reporting since
  #      we have lots of caches of this sort
  rdbVtxLruStats: array[StateType, array[VertexType, LruCounter]]
  rdbKeyLruStats: array[StateType, LruCounter]

var
  rdbVtxLruStatsMetric {.used.} = RdbVtxLruCounter.newCollector(
    "aristo_rdb_vtx_lru_total",
    "Vertex LRU lookup (hit/miss, world/account, branch/leaf)",
    labels = ["state", "vtype", "hit"],
  )
  rdbKeyLruStatsMetric {.used.} = RdbKeyLruCounter.newCollector(
    "aristo_rdb_key_lru_total", "HashKey LRU lookup", labels = ["state", "hit"]
  )

template to(v: RootedVertexID, T: type StateType): StateType =
  if v.root == VertexID(1): StateType.World else: StateType.Account

template inc(v: var LruCounter, hit: bool) =
  discard v[hit].fetchAdd(1, moRelaxed)

template get(v: LruCounter, hit: bool): uint64 =
  v[hit].load(moRelaxed)

method collect*(collector: RdbVtxLruCounter, output: MetricHandler) =
  let timestamp = collector.now()

  # We don't care about synchronization between each type of metric or between
  # the metrics thread and others since small differences like this don't matter
  for state in StateType:
    for vtype in VertexType:
      for hit in [false, true]:
        output(
          name = "aristo_rdb_vtx_lru_total",
          value = float64(rdbVtxLruStats[state][vtype].get(hit)),
          labels = ["state", "vtype", "hit"],
          labelValues = [$state, $vtype, $ord(hit)],
          timestamp = timestamp,
        )

method collect*(collector: RdbKeyLruCounter, output: MetricHandler) =
  let timestamp = collector.now()

  for state in StateType:
    for hit in [false, true]:
      output(
        name = "aristo_rdb_key_lru_total",
        value = float64(rdbKeyLruStats[state].get(hit)),
        labels = ["state", "hit"],
        labelValues = [$state, $ord(hit)],
        timestamp = timestamp,
      )

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getAdm*(rdb: RdbInst; xid: AdminTabID): Result[Blob,(AristoError,string)] =
  var res: Blob
  let onData = proc(data: openArray[byte]) =
    res = @data

  let gotData = rdb.admCol.get(xid.toOpenArray, onData).valueOr:
     const errSym = RdbBeDriverGetAdmError
     when extraTraceMessages:
       trace logTxt "getAdm", xid, error=errSym, info=error
     return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res = EmptyBlob
  ok move(res)

proc getKey*(
    rdb: var RdbInst;
    rvid: RootedVertexID;
      ): Result[HashKey,(AristoError,string)] =
  # Try LRU cache first
  var rc = rdb.rdKeyLru.lruFetch(rvid.vid)
  if rc.isOK:
    rdbKeyLruStats[rvid.to(StateType)].inc(true)
    return ok(move(rc.value))

  rdbKeyLruStats[rvid.to(StateType)].inc(false)

  # Otherwise fetch from backend database
  var res: Result[HashKey,(AristoError,string)]
  let onData = proc(data: openArray[byte]) =
    res = HashKey.fromBytes(data).mapErr(proc(): auto =
      (RdbHashKeyExpected,""))

  let gotData = rdb.keyCol.get(rvid.blobify().data(), onData).valueOr:
     const errSym = RdbBeDriverGetKeyError
     when extraTraceMessages:
       trace logTxt "getKey", rvid, error=errSym, info=error
     return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res = ok(VOID_HASH_KEY)
  elif res.isErr():
    return res # Parsing failed

  # Update cache and return
  ok rdb.rdKeyLru.lruAppend(rvid.vid, res.value(), RdKeyLruMaxSize)

proc getVtx*(
    rdb: var RdbInst;
    rvid: RootedVertexID;
      ): Result[VertexRef,(AristoError,string)] =
  # Try LRU cache first
  var rc = rdb.rdVtxLru.lruFetch(rvid.vid)
  if rc.isOK:
    rdbVtxLruStats[rvid.to(StateType)][rc.value().vType].inc(true)
    return ok(move(rc.value))

  # Otherwise fetch from backend database
  var res: Result[VertexRef,(AristoError,string)]
  let onData = proc(data: openArray[byte]) =
    res = data.deblobify(VertexRef).mapErr(proc(error: AristoError): auto =
      (error,""))

  let gotData = rdb.vtxCol.get(rvid.blobify().data(), onData).valueOr:
    const errSym = RdbBeDriverGetVtxError
    when extraTraceMessages:
      trace logTxt "getVtx", vid, error=errSym, info=error
    return err((errSym,error))

  if not gotData:
    # As a hack, we count missing data as leaf nodes
    rdbVtxLruStats[rvid.to(StateType)][VertexType.Leaf].inc(false)
    return ok(VertexRef(nil))

  if res.isErr():
    return res # Parsing failed

  rdbVtxLruStats[rvid.to(StateType)][res.value().vType].inc(false)

  # Update cache and return
  ok rdb.rdVtxLru.lruAppend(rvid.vid, res.value(), RdVtxLruMaxSize)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

when defined(printStatsAtExit):
  # Useful hack for printing exact metrics to compare runs with different
  # settings
  import std/[exitprocs, strformat]
  addExitProc(
    proc() =
      block vtx:
        var misses, hits: uint64
        echo "vtxLru(", RdVtxLruMaxSize, ")"
        echo "   state    vtype       miss        hit      total hitrate"
        for state in StateType:
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
        echo "keyLru(", RdKeyLruMaxSize, ") "

        echo "   state       miss        hit      total hitrate"

        for state in StateType:
          let
            (miss, hit) =
              (rdbKeyLruStats[state].get(false), rdbKeyLruStats[state].get(true))
            hitRate = float64(hit * 100) / (float64(hit + miss))
          misses += miss
          hits += hit

          echo &"{state:>8} {miss:>10} {hit:>10} {miss+hit:>10} {hitRate:>5.2f}%"

        let hitRate = float64(hits * 100) / (float64(hits + misses))
        echo &"     all {misses:>10} {hits:>10} {misses+hits:>10} {hitRate:>5.2f}%"
  )
