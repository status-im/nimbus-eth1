# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  rocksdb,
  results,
  ../../[aristo_blobify, aristo_desc],
  ./rdb_desc,
  std/concurrency/atomics

const extraTraceMessages = false ## Enable additional logging noise

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "aristo-rocksdb"

when defined(metrics):
  import metrics

  type
    RdbVtxLruCounter = ref object of Counter
    RdbKeyLruCounter = ref object of Counter
    RdbBranchLruCounter = ref object of Counter

  var
    rdbVtxLruStatsMetric {.used.} = RdbVtxLruCounter.newCollector(
      "aristo_rdb_vtx_lru_total",
      "Vertex LRU lookup (hit/miss, world/account, branch/leaf)",
      labels = ["state", "vtype", "hit"],
      standardType = "counter",
    )
    rdbKeyLruStatsMetric {.used.} = RdbKeyLruCounter.newCollector(
      "aristo_rdb_key_lru_total",
      "HashKey LRU lookup",
      labels = ["state", "hit"],
      standardType = "counter",
    )
    rdbBranchLruStatsMetric {.used.} = RdbBranchLruCounter.newCollector(
      "aristo_rdb_branch_lru_total",
      "Branch LRU lookup",
      labels = ["state", "hit"],
      standardType = "counter",
    )

  method collect*(collector: RdbVtxLruCounter, output: MetricHandler) =
    let timestamp = collector.now()

    # We don't care about synchronization between each type of metric or between
    # the metrics thread and others since small differences like this don't matter
    for state in RdbStateType:
      for vtype in RdbVertexType:
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

  method collect*(collector: RdbBranchLruCounter, output: MetricHandler) =
    let timestamp = collector.now()

    for state in RdbStateType:
      for hit in [false, true]:
        output(
          name = "aristo_rdb_branch_lru_total",
          value = float64(rdbBranchLruStats[state].get(hit)),
          labels = ["state", "hit"],
          labelValues = [$state, $ord(hit)],
          timestamp = timestamp,
        )

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getAdm*(rdb: RdbInst): Result[seq[byte], (AristoError, string)] =
  var res: seq[byte]
  let onData = proc(data: openArray[byte]) =
    res = @data

  let gotData = rdb.vtxCol.get(AdmKey, onData).valueOr:
    const errSym = RdbBeDriverGetAdmError
    when extraTraceMessages:
      trace logTxt "getAdm", xid, error = errSym, info = error
    return err((errSym, error))

  # Correct result if needed
  if not gotData:
    res = EmptyBlob
  ok move(res)

proc getKey*(
    rdb: var RdbInst, rvid: RootedVertexID, flags: set[GetVtxFlag]
): Result[(HashKey, VertexRef), (AristoError, string)] =
  block:
    # Try LRU cache first
    let rc =
      if GetVtxFlag.PeekCache in flags:
        rdb.rdKeyLru.peek(rvid.vid)
      else:
        rdb.rdKeyLru.get(rvid.vid)

    if rc.isOk:
      rdbKeyLruStats[rvid.to(RdbStateType)].inc(true)
      return ok((rc.value, nil))

    rdbKeyLruStats[rvid.to(RdbStateType)].inc(false)

  block:
    # We don't store keys for leaves, no need to hit the database
    rdb.rdVtxLru.withPeek(rvid, cached):
      let vtx = cached.data().deblobify(VertexRef).expect("valid data in db")
      if vtx.vType in Leaves:
        return ok((VOID_HASH_KEY, vtx))

  # Otherwise fetch from backend database
  var
    vtxBuf {.noinit.}: VertexBuf
    dataLen: int

  let gotData = rdb.vtxCol.get(rvid.blobify().data(), vtxBuf.buf, dataLen).valueOr:
    const errSym = RdbBeDriverGetKeyError
    when extraTraceMessages:
      trace logTxt "getKey", rvid, error = errSym, info = error
    return err((errSym, error))

  if not gotData:
    return ok((VOID_HASH_KEY, nil))

  vtxBuf.n = typeof(vtxBuf.n)(dataLen)

  let res = vtxBuf.data().deblobify(HashKey)

  # Update cache and return - in peek mode, avoid evicting cache items
  if res.isSome() and
      (GetVtxFlag.PeekCache notin flags or rdb.rdKeyLru.len < rdb.rdKeyLru.capacity):
    rdb.rdKeyLru.put(rvid.vid, res.value())

  if res.isNone() and rdb.rdVtxLru.len < rdb.rdVtxLru.capacity:
    # Don't invalidate vertex cache entries because of key reads - the latter
    # follow a different access pattern!
    rdb.rdVtxLru.put(rvid, vtxBuf)

  let vtx =
    if res.isNone():
      vtxBuf.data().deblobify(VertexRef).expect("valid data in db")
    else:
      nil

  ok (res.valueOr(VOID_HASH_KEY), vtx)

func cmpKeyBuf(a, b: RVidBuf): int =
  let n = min(int(a.len), int(b.len))
  for i in 0 ..< n:
    if a.buf[i] != b.buf[i]:
      return int(a.buf[i]) - int(b.buf[i])
  int(a.len) - int(b.len)

proc getKeys*(
    rdb: var RdbInst,
    rvids: openArray[RootedVertexID],
    keyvtxs: var openArray[(HashKey, VertexRef)],
    flags: set[GetVtxFlag],
): Result[void, (AristoError, string)] =
  doAssert rvids.len <= MAX_KEYS_FETCH and keyvtxs.len == rvids.len

  var
    fetchIdxs {.noinit.}: array[MAX_KEYS_FETCH, uint8]
    nFetch = 0

  for i, rvid in rvids:
    block lookup:
      block:
        let rc =
          if GetVtxFlag.PeekCache in flags:
            rdb.rdKeyLru.peek(rvid.vid)
          else:
            rdb.rdKeyLru.get(rvid.vid)

        if rc.isOk:
          rdbKeyLruStats[rvid.to(RdbStateType)].inc(true)
          keyvtxs[i] = (rc.value, VertexRef(nil))
          break lookup

        rdbKeyLruStats[rvid.to(RdbStateType)].inc(false)

      block:
        var leafVtx: VertexRef
        rdb.rdVtxLru.withPeek(rvid, cached):
          let vtx = cached.data().deblobify(VertexRef).expect("valid data in db")
          if vtx.vType in Leaves:
            leafVtx = vtx

        if not leafVtx.isNil:
          keyvtxs[i] = (VOID_HASH_KEY, leafVtx)
          break lookup

      fetchIdxs[nFetch] = uint8 i
      inc nFetch

  if nFetch == 0:
    return ok()

  var
    keyBufs {.noinit.}: array[MAX_KEYS_FETCH, RVidBuf]
    keySlices {.noinit.}: array[MAX_KEYS_FETCH, RocksDbSlice]
    vtxBufs {.noinit.}: array[MAX_KEYS_FETCH, VertexBuf]
    valueSlices {.noinit.}: array[MAX_KEYS_FETCH, RocksDbMutSlice]

  for j in 0 ..< nFetch:
    keyBufs[j] = rvids[int fetchIdxs[j]].blobify()

  # Keys must be in comparator order because multiGet is called with sortedInput = true.
  # Insertion sort keeps this allocation free, unlike `algorithm.sort`.
  for j in 1 ..< nFetch:
    let
      keyBuf = keyBufs[j]
      fetchIdx = fetchIdxs[j]
    var k = j
    while k > 0 and cmpKeyBuf(keyBufs[k - 1], keyBuf) > 0:
      keyBufs[k] = keyBufs[k - 1]
      fetchIdxs[k] = fetchIdxs[k - 1]
      dec k
    keyBufs[k] = keyBuf
    fetchIdxs[k] = fetchIdx

  for j in 0 ..< nFetch:
    keySlices[j] =
      RocksDbSlice.init(keyBufs[j].buf.toOpenArray(0, int(keyBufs[j].len) - 1))
    valueSlices[j] = RocksDbMutSlice.init(vtxBufs[j].buf)

  rdb.vtxCol.multiGet(
    keySlices.toOpenArray(0, nFetch - 1),
    valueSlices.toOpenArray(0, nFetch - 1),
    sortedInput = true,
  ).isOkOr:
    return err((RdbBeDriverGetKeyError, error))

  for j in 0 ..< nFetch:
    let i = int fetchIdxs[j]

    if not valueSlices[j].found:
      keyvtxs[i] = (VOID_HASH_KEY, VertexRef(nil))
      continue

    vtxBufs[j].n = typeof(vtxBufs[j].n)(valueSlices[j].len)

    let
      rvid = rvids[i]
      res = vtxBufs[j].data().deblobify(HashKey)

    if res.isSome() and
        (GetVtxFlag.PeekCache notin flags or rdb.rdKeyLru.len < rdb.rdKeyLru.capacity):
      rdb.rdKeyLru.put(rvid.vid, res.value())

    if res.isNone() and rdb.rdVtxLru.len < rdb.rdVtxLru.capacity:
      rdb.rdVtxLru.put(rvid, vtxBufs[j])

    keyvtxs[i] =
      if res.isSome():
        (res.value(), VertexRef(nil))
      else:
        (
          VOID_HASH_KEY,
          vtxBufs[j].data().deblobify(VertexRef).expect("valid data in db"),
        )

  ok()

proc getVtx*(
    rdb: var RdbInst, rvid: RootedVertexID, flags: set[GetVtxFlag]
): Result[VertexRef, (AristoError, string)] =
  # Try LRU cache first
  block:
    let rc =
      if GetVtxFlag.PeekCache in flags:
        rdb.rdBranchLru.peek(rvid.vid)
      else:
        rdb.rdBranchLru.get(rvid.vid)
    if rc.isOk():
      rdbBranchLruStats[rvid.to(RdbStateType)].inc(true)
      return ok(BranchRef.init(rc[][0], rc[][1]))

  block:
    var vtx: VertexRef
    if GetVtxFlag.PeekCache in flags:
      rdb.rdVtxLru.withPeek(rvid, cached):
        vtx = cached.data().deblobify(VertexRef).expect("valid data in db")
    else:
      rdb.rdVtxLru.withGet(rvid, cached):
        vtx = cached.data().deblobify(VertexRef).expect("valid data in db")

    if vtx != nil:
      rdbVtxLruStats[rvid.to(RdbStateType)][vtx.vType.to(RdbVertexType)].inc(
        true
      )
      return ok(vtx)

  # Otherwise fetch from backend database
  var
    vtxBuf {.noinit.}: VertexBuf
    dataLen: int

  let gotData = rdb.vtxCol.get(rvid.blobify().data(), vtxBuf.buf, dataLen).valueOr:
    const errSym = RdbBeDriverGetVtxError
    when extraTraceMessages:
      trace logTxt "getVtx", vid, error = errSym, info = error
    return err((errSym, error))

  if not gotData:
    rdbVtxLruStats[rvid.to(RdbStateType)][RdbVertexType.Empty].inc(false)
    return ok(VertexRef(nil))

  vtxBuf.n = typeof(vtxBuf.n)(dataLen)

  let res = vtxBuf.data().deblobify(VertexRef)

  if res.isErr():
    return err((res.error(), "Parsing failed")) # Parsing failed

  if res.value.vType == Branch:
    rdbBranchLruStats[rvid.to(RdbStateType)].inc(false)
  else:
    rdbVtxLruStats[rvid.to(RdbStateType)][res.value().vType.to(RdbVertexType)].inc(
      false
    )

  # Update cache and return - in peek mode, avoid evicting cache items
  if GetVtxFlag.PeekCache notin flags:
    if res.value.vType == Branch and BranchRef(res.value()).leafMask == 0:
      let vtx = BranchRef(res.value())
      rdb.rdBranchLru.put(rvid.vid, (vtx.startVid, vtx.used))
    else:
      rdb.rdVtxLru.put(rvid, vtxBuf)

  ok res.value()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
