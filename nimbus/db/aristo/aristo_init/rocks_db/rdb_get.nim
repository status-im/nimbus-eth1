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

var
  rdbVtxLruStatsMetric {.used.} = RdbVtxLruCounter.newCollector(
    "aristo_rdb_vtx_lru_total",
    "Vertex LRU lookup (hit/miss, world/account, branch/leaf)",
    labels = ["state", "vtype", "hit"],
  )
  rdbKeyLruStatsMetric {.used.} = RdbKeyLruCounter.newCollector(
    "aristo_rdb_key_lru_total", "HashKey LRU lookup", labels = ["state", "hit"]
  )

method collect*(collector: RdbVtxLruCounter, output: MetricHandler) =
  let timestamp = collector.now()

  # We don't care about synchronization between each type of metric or between
  # the metrics thread and others since small differences like this don't matter
  for state in RdbStateType:
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

  for state in RdbStateType:
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

proc getAdm*(rdb: RdbInst; xid: AdminTabID): Result[seq[byte],(AristoError,string)] =
  var res: seq[byte]
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
  var rc = rdb.rdKeyLru.get(rvid.vid)
  if rc.isOK:
    rdbKeyLruStats[rvid.to(RdbStateType)].inc(true)
    return ok(move(rc.value))

  rdbKeyLruStats[rvid.to(RdbStateType)].inc(false)

  # Otherwise fetch from backend database
  # A threadvar is used to avoid allocating an environment for onData
  var res{.threadvar.}: Opt[HashKey]
  let onData = proc(data: openArray[byte]) =
    res = HashKey.fromBytes(data)

  let gotData = rdb.keyCol.get(rvid.blobify().data(), onData).valueOr:
     const errSym = RdbBeDriverGetKeyError
     when extraTraceMessages:
       trace logTxt "getKey", rvid, error=errSym, info=error
     return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res.ok(VOID_HASH_KEY)
  elif res.isErr():
    return err((RdbHashKeyExpected,"")) # Parsing failed

  # Update cache and return
  rdb.rdKeyLru.put(rvid.vid, res.value())

  ok res.value()

proc getVtx*(
    rdb: var RdbInst;
    rvid: RootedVertexID;
    flags: set[GetVtxFlag];
      ): Result[VertexRef,(AristoError,string)] =
  # Try LRU cache first
  var rc =
    if GetVtxFlag.PeekCache in flags:
      rdb.rdVtxLru.peek(rvid.vid)
    else:
      rdb.rdVtxLru.get(rvid.vid)

  if rc.isOK:
    rdbVtxLruStats[rvid.to(RdbStateType)][rc.value().vType].inc(true)
    return ok(move(rc.value))

  # Otherwise fetch from backend database
  # A threadvar is used to avoid allocating an environment for onData
  var res {.threadvar.}: Result[VertexRef,AristoError]
  let onData = proc(data: openArray[byte]) =
    res = data.deblobify(VertexRef)

  let gotData = rdb.vtxCol.get(rvid.blobify().data(), onData).valueOr:
    const errSym = RdbBeDriverGetVtxError
    when extraTraceMessages:
      trace logTxt "getVtx", vid, error=errSym, info=error
    return err((errSym,error))

  if not gotData:
    # As a hack, we count missing data as leaf nodes
    rdbVtxLruStats[rvid.to(RdbStateType)][VertexType.Leaf].inc(false)
    return ok(VertexRef(nil))

  if res.isErr():
    return err((res.error(), "Parsing failed")) # Parsing failed

  rdbVtxLruStats[rvid.to(RdbStateType)][res.value().vType].inc(false)

  # Update cache and return - in peek mode, avoid evicting cache items
  if GetVtxFlag.PeekCache notin flags or rdb.rdVtxLru.len < rdb.rdVtxLru.capacity:
    rdb.rdVtxLru.put(rvid.vid, res.value())

  ok res.value()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
