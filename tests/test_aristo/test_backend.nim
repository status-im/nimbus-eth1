# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB records merge test

import
  std/[algorithm, sequtils, sets, tables],
  eth/common,
  stew/results,
  unittest2,
  ../../nimbus/sync/protocol,
  ../../nimbus/db/aristo/aristo_init/[
    aristo_memory],
  ../../nimbus/db/aristo/[
    aristo_desc, aristo_debug, aristo_hashify, aristo_init, aristo_layer,
    aristo_merge],
  ./test_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc mergeData(
    db: AristoDb;
    rootKey: HashKey;
    rootVid: VertexID;
    proof: openArray[SnapProof];
    leafs: openArray[LeafTiePayload];
    noisy: bool;
      ): bool =
  ## Simplified loop body of `test_mergeProofAndKvpList()`
  if 0 < proof.len:
    let rc = db.merge(rootKey, rootVid)
    if rc.isErr:
      check rc.error == AristoError(0)
      return

    let proved = db.merge(proof, rc.value)
    if proved.error notin {AristoError(0),MergeHashKeyCachedAlready}:
      check proved.error in {AristoError(0),MergeHashKeyCachedAlready}
      return

  let merged = db.merge leafs
  if merged.error notin {AristoError(0), MergeLeafPathCachedAlready}:
    check merged.error in {AristoError(0), MergeLeafPathCachedAlready}
    return

  block:
    let rc = db.hashify()
    if rc.isErr:
      when true: # and false:
        noisy.say "***", "dataMerge(9)",
          " nLeafs=", leafs.len,
          "\n    cache dump\n    ", db.pp,
          "\n    backend dump\n    ", db.backend.AristoTypedBackendRef.pp(db)
      check rc.error == (VertexID(0),AristoError(0))
      return

  true

proc verify(
    ly: AristoLayerRef;                      # Database layer
    be: MemBackendRef;                       # Backend
    noisy: bool;
      ): bool =
  ## ..

  let
    beSTab = be.walkVtx.toSeq.mapIt((it[1],it[2])).toTable
    beKMap = be.walkKey.toSeq.mapIt((it[1],it[2])).toTable
    beIdg = be.walkIdg.toSeq

  for vid in beSTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let
      nVtx = ly.sTab.getOrVoid vid
      mVtx = beSTab.getOrVoid vid
    if not nVtx.isValid and not mVtx.isValid:
      check nVtx != VertexRef(nil)
      check mVtx != VertexRef(nil)
      return
    if nVtx != mVtx:
      noisy.say "***", "verify",
        " beType=", be.typeof,
        " vid=", vid.pp,
        " nVtx=", nVtx.pp,
        " mVtx=", mVtx.pp
      check nVtx == mVtx
      return

  if beSTab.len != ly.sTab.len or
     beKMap.len != ly.kMap.len:
    check beSTab.len == ly.sTab.len
    check beKMap.len == ly.kMap.len
    return

  true

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_backendConsistency*(
    noisy: bool;
    list: openArray[ProofTrieData];          # Test data
    resetDb = false;
      ): bool =
  ## Import accounts
  var
    ndb: AristoDb                            # Reference cache
    mdb: AristoDb                            # Memory backend database
    rootKey = HashKey.default
    count = 0

  for n,w in list:
    if w.root != rootKey or resetDB:
      rootKey = w.root
      count = 0
      ndb = AristoDb.init(BackendNone)
      mdb = AristoDb.init(BackendMemory)
    count.inc

    check ndb.backend.isNil
    check not mdb.backend.isNil

    when true and false:
      noisy.say "***", "beCon(1) <", n, "/", list.len-1, ">", " groups=", count

    block:
      let
        rootVid = VertexID(1)
        leafs = w.kvpLst.mapRootVid VertexID(1) # for merging it into main trie

      let ndbOk = ndb.mergeData(rootKey, rootVid, w.proof, leafs, noisy=false)
      if not ndbOk:
        check ndbOk
        return

      when true and false:
        noisy.say "***", "beCon(2) <", n, "/", list.len-1, ">",
          " groups=", count,
          "\n    cache dump\n    ", ndb.pp,
          "\n    backend dump\n    ", ndb.backend.AristoTypedBackendRef.pp(ndb)

      when true and false:
        noisy.say "***", "beCon(3) <", n, "/", list.len-1, ">",
          " groups=", count,
          "\n    mdb cache\n    ", mdb.pp,
          "\n    mdb backend\n    ", mdb.backend.AristoTypedBackendRef.pp(ndb)
  
      let mdbOk = mdb.mergeData(rootKey, rootVid, w.proof, leafs, noisy=false)
      if not mdbOk:
        check mdbOk
        return

    when true and false:
      noisy.say "***", "beCon(3) <", n, "/", list.len-1, ">", " groups=", count

    let
      mdbPreSaveCache = mdb.pp
      mdbPreSaveBackend = mdb.backend.AristoTypedBackendRef.pp(ndb)

    # Store onto backend database
    let mdbHist = block:
      #noisy.say "***", "db-dump\n    ", mdb.pp
      let rc = mdb.save
      if rc.isErr:
        check rc.error == AristoError(0)
        return
      rc.value

    if not ndb.top.verify(mdb.backend.MemBackendRef, noisy):
      when true: # and false:
        noisy.say "***", "beCon(4) <", n, "/", list.len-1, ">",
          " groups=", count,
          "\n    ndb cache\n    ", ndb.pp,
          "\n    ndb backend\n    ", ndb.backend.AristoTypedBackendRef.pp(ndb),
          #"\n    -------------",
          #"\n    mdb pre-save cache\n    ", mdbPreSaveCache,
          #"\n    mdb pre-save backend\n    ", mdbPreSaveBackend,
          "\n    -------------",
          "\n    mdb cache\n    ", mdb.pp,
          "\n    mdb backend\n    ", mdb.backend.AristoTypedBackendRef.pp(ndb)
      return

    when true and false:
      noisy.say "***", "beCon(8) <", n, "/", list.len-1, ">",
        " groups=", count,
        "\n    ndb cache\n    ", ndb.pp,
        "\n    ndb backend\n    ", ndb.backend.AristoTypedBackendRef.pp(ndb),
        "\n    -------------",
        "\n    mdb cache\n    ", mdb.pp,
        "\n    mdb backend\n    ", mdb.backend.AristoTypedBackendRef.pp(ndb)

    when true and false:
      noisy.say "***", "beCon(9) <", n, "/", list.len-1, ">", " groups=", count

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
