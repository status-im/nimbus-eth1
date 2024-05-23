# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB records merge test

import
  std/[algorithm, hashes, sequtils, sets, strutils, tables],
  eth/common,
  results,
  unittest2,
  stew/endians2,
  ../../nimbus/sync/protocol,
  ../../nimbus/db/aristo/[
    aristo_blobify,
    aristo_debug,
    aristo_desc,
    aristo_desc/desc_backend,
    aristo_get,
    aristo_init/memory_db,
    aristo_init/rocks_db,
    aristo_layers,
    aristo_merge,
    aristo_persistent,
    aristo_tx,
    aristo_vid],
  ../replay/xcheck,
  ./test_helpers

const
  BlindHash = EmptyBlob.hash

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func hash(filter: FilterRef): Hash =
  ## Unique hash/filter -- cannot use de/blobify as the expressions
  ## `filter.blobify` and `filter.blobify.value.deblobify.value.blobify` are
  ## not necessarily the same binaries due to unsorted tables.
  ##
  var h = BlindHash
  if not filter.isNil:
    h = h !& filter.src.hash
    h = h !& filter.trg.hash

    for w in filter.vGen.vidReorg:
      h = h !& w.uint64.hash

    for w in filter.sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
      let data = filter.sTab.getOrVoid(w).blobify.get(otherwise = EmptyBlob)
      h = h !& (w.uint64.toBytesBE.toSeq & data).hash

    for w in filter.kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
      let data = @(filter.kMap.getOrVoid(w).data)
      h = h !& (w.uint64.toBytesBE.toSeq & data).hash

  !$h

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc verify(
    ly: LayerRef;                            # Database layer
    be: BackendRef;                          # Backend
    noisy: bool;
      ): bool =

  proc verifyImpl[T](noisy: bool; ly: LayerRef; be: T): bool =
    ## ..
    let
      beSTab = be.walkVtx.toSeq.mapIt((it[0],it[1])).toTable
      beKMap = be.walkKey.toSeq.mapIt((it[0],it[1])).toTable

    for vid in beSTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
      let
        nVtx = ly.delta.sTab.getOrVoid vid
        mVtx = beSTab.getOrVoid vid

      xCheck (nVtx != VertexRef(nil))
      xCheck (mVtx != VertexRef(nil))
      xCheck nVtx == mVtx:
        noisy.say "***", "verify",
          " beType=", be.typeof,
          " vid=", vid.pp,
          " nVtx=", nVtx.pp,
          " mVtx=", mVtx.pp

    xCheck beSTab.len == ly.delta.sTab.len
    xCheck beKMap.len == ly.delta.kMap.len:
      let
        a = ly.delta.kMap.keys.toSeq.toHashSet
        b = beKMap.keys.toSeq.toHashSet
      noisy.say "***", "verify",
        " delta=", (a -+- b).pp

    true

  case be.kind:
  of BackendMemory:
    noisy.verifyImpl(ly, be.MemBackendRef)
  of BackendRocksDB:
    noisy.verifyImpl(ly, be.RdbBackendRef)
  else:
    raiseAssert "Oops, unsupported backend " & $be.kind


proc verifyFilters(
    db: AristoDbRef;
    tab: Table[QueueID,Hash];
    noisy: bool;
      ): bool =

  proc verifyImpl[T](noisy: bool; tab: Table[QueueID,Hash]; be: T): bool =
    ## Compare stored filters against registered ones
    var n = 0
    for (fid,filter) in walkFilBe(be):
      let
        filterHash = filter.hash
        registered = tab.getOrDefault(fid, BlindHash)

      xCheck (registered != BlindHash)
      xCheck registered == filterHash:
        noisy.say "***", "verifyFiltersImpl",
          " n=", n+1,
          " fid=", fid.pp,
          " filterHash=", filterHash.int.toHex,
          " registered=", registered.int.toHex

      n.inc

    xCheck n == tab.len
    true

  ## Wrapper
  let be = db.backend
  case be.kind:
  of BackendMemory:
    noisy.verifyImpl(tab, be.MemBackendRef)
  of BackendRocksDB:
    noisy.verifyImpl(tab, be.RdbBackendRef)
  else:
    raiseAssert "Oops, unsupported backend " & $be.kind


proc verifyKeys(
    db: AristoDbRef;
    noisy: bool;
      ): bool =

  proc verifyImpl[T](noisy: bool; db: AristoDbRef): bool =
    ## Check for zero keys
    var zeroKeys: seq[VertexID]
    for (vid,vtx) in T.walkPairs(db):
      if vtx.isValid and not db.getKey(vid).isValid:
        zeroKeys.add vid

    xCheck zeroKeys == EmptyVidSeq:
      noisy.say "***", "verifyKeys(1)",
        "\n    zeroKeys=", zeroKeys.pp,
        #"\n    db\n    ", db.pp(backendOk=true),
        ""
    true

  ## Wrapper
  let be = db.backend
  case be.kind:
  of BackendVoid:
    verifyImpl[VoidBackendRef](noisy, db)
  of BackendMemory:
    verifyImpl[MemBackendRef](noisy, db)
  of BackendRocksDB:
    verifyImpl[RdbBackendRef](noisy, db)

# -----------

proc collectFilter(
    db: AristoDbRef;
    filter: FilterRef;
    tab: var Table[QueueID,Hash];
    noisy: bool;
      ): bool =
  ## Store filter on permanent BE and register digest
  if not filter.isNil:
    let
      fid = QueueID(7 * (tab.len + 1)) # just some number
      be = db.backend
      tx = be.putBegFn()

    be.putFilFn(tx, @[(fid,filter)])
    let rc = be.putEndFn tx
    xCheckRc rc.error == 0

    tab[fid] = filter.hash

  true

proc mergeData(
    db: AristoDbRef;
    rootKey: Hash256;
    rootVid: VertexID;
    proof: openArray[SnapProof];
    leafs: openArray[LeafTiePayload];
    noisy: bool;
      ): bool =
  ## Simplified loop body of `test_mergeProofAndKvpList()`
  if 0 < proof.len:
    let root = block:
      let rc = db.merge(rootKey, rootVid)
      xCheckRc rc.error == 0
      rc.value

    let nMerged = block:
      let rc = db.merge(proof, root)
      xCheckRc rc.error == 0
      rc.value
    discard nMerged # Result is currently unused

  let merged = db.mergeList(leafs, noisy=noisy)
  xCheck merged.error in {AristoError(0), MergeLeafPathCachedAlready}

  block:
    let rc = db.hashify(noisy = noisy)
    xCheckRc rc.error == (0,0):
      noisy.say "***", "dataMerge (8)",
        " nProof=", proof.len,
        " nLeafs=", leafs.len,
        " error=", rc.error,
        #"\n    db\n    ", db.pp(backendOk=true),
        ""
  block:
    xCheck db.verifyKeys(noisy):
      noisy.say "***", "dataMerge (9)",
        " nProof=", proof.len,
        " nLeafs=", leafs.len,
        #"\n    db\n    ", db.pp(backendOk=true),
        ""
  true

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testBackendConsistency*(
    noisy: bool;
    list: openArray[ProofTrieData];          # Test data
    rdbPath = "";                            # Rocks DB storage directory
    resetDb = false;
      ): bool =
  ## Import accounts
  var
    filTab: Table[QueueID,Hash]              # Filter register
    ndb = AristoDbRef()                      # Reference cache
    mdb = AristoDbRef()                      # Memory backend database
    rdb = AristoDbRef()                      # Rocks DB backend database
    rootKey = Hash256()                      # Root key
    count = 0

  defer:
    rdb.finish(flush=true)

  for n,w in list:
    if w.root != rootKey or resetDb:
      rootKey = w.root
      count = 0
      ndb = AristoDbRef.init()
      mdb = AristoDbRef.init MemBackendRef

      if not rdb.backend.isNil: # ignore bootstrap
        let verifyFiltersOk = rdb.verifyFilters(filTab, noisy)
        xCheck verifyFiltersOk
        filTab.clear
      rdb.finish(flush=true)
      if 0 < rdbPath.len:
        let rc = AristoDbRef.init(RdbBackendRef, rdbPath)
        xCheckRc rc.error == 0
        rdb = rc.value
      else:
        rdb = AristoDbRef.init MemBackendRef # fake `rdb` database

      # Disable automated filter management, still allow filter table access
      # for low level read/write testing.
      rdb.backend.journal = QidSchedRef(nil)
    count.inc

    xCheck ndb.backend.isNil
    xCheck not mdb.backend.isNil
    xCheck ndb.vGen == mdb.vGen
    xCheck ndb.top.final.fRpp.len == mdb.top.final.fRpp.len

    when true and false:
      noisy.say "***", "beCon(1) <", n, "/", list.len-1, ">",
        " groups=", count,
        "\n    ndb\n    ", ndb.pp(backendOk = true),
        "\n    -------------",
        "\n    mdb\n    ", mdb.pp(backendOk = true),
        #"\n    -------------",
        #"\n    rdb\n    ", rdb.pp(backendOk = true),
        "\n    -------------"

    block:
      let
        rootVid = VertexID(1)
        leafs = w.kvpLst.mapRootVid rootVid # for merging it into main trie

      let ndbOk = ndb.mergeData(rootKey, rootVid, w.proof, leafs, noisy=false)
      xCheck ndbOk

      let mdbOk = mdb.mergeData(rootKey, rootVid, w.proof, leafs, noisy=false)
      xCheck mdbOk

      let rdbOk = rdb.mergeData(rootKey, rootVid, w.proof, leafs, noisy=false)
      xCheck rdbOk

    when true and false:
      noisy.say "***", "beCon(2) <", n, "/", list.len-1, ">",
        " groups=", count,
        "\n    ndb\n    ", ndb.pp(backendOk = true),
        "\n    -------------",
        "\n    mdb\n    ", mdb.pp(backendOk = true),
        #"\n    -------------",
        #"\n    rdb\n    ", rdb.pp(backendOk = true),
        "\n    -------------"

    var
      mdbPreSave = ""
      rdbPreSave {.used.} = ""
    when true and false:
      mdbPreSave = mdb.pp() # backendOk = true)
      rdbPreSave = rdb.pp() # backendOk = true)

    # Provide filter, store filter on permanent BE, and register filter digest
    block:
      let rc = mdb.persist(chunkedMpt=true)
      xCheckRc rc.error == 0
      let collectFilterOk = rdb.collectFilter(mdb.roFilter, filTab, noisy)
      xCheck collectFilterOk

    # Store onto backend database
    block:
      #noisy.say "***", "db-dump\n    ", mdb.pp
      let rc = mdb.persist(chunkedMpt=true)
      xCheckRc rc.error == 0
    block:
      let rc = rdb.persist(chunkedMpt=true)
      xCheckRc rc.error == 0

    xCheck ndb.vGen == mdb.vGen
    xCheck ndb.top.final.fRpp.len == mdb.top.final.fRpp.len

    block:
      ndb.top.final.pPrf.clear # let it look like mdb/rdb
      xCheck mdb.pPrf.len == 0
      xCheck rdb.pPrf.len == 0

      let mdbVerifyOk = ndb.top.verify(mdb.backend, noisy)
      xCheck mdbVerifyOk:
        when true: # and false:
          noisy.say "***", "beCon(4) <", n, "/", list.len-1, ">",
            " groups=", count,
            "\n    ndb\n    ", ndb.pp(backendOk = true),
            "\n    -------------",
            "\n    mdb pre-stow\n    ", mdbPreSave,
            "\n    -------------",
            "\n    mdb\n    ", mdb.pp(backendOk = true),
            "\n    -------------"

      let rdbVerifyOk = ndb.top.verify(rdb.backend, noisy)
      xCheck rdbVerifyOk:
        when true and false:
          noisy.say "***", "beCon(5) <", n, "/", list.len-1, ">",
            " groups=", count,
            "\n    ndb\n    ", ndb.pp(backendOk = true),
            "\n    -------------",
            "\n    rdb pre-stow\n    ", rdbPreSave,
            "\n    -------------",
            "\n    rdb\n    ", rdb.pp(backendOk = true),
            #"\n    -------------",
            #"\n    mdb\n    ", mdb.pp(backendOk = true),
            "\n    -------------"

    when true and false:
      noisy.say "***", "beCon(9) <", n, "/", list.len-1, ">", " groups=", count

  # Finally ...
  block:
    let verifyFiltersOk = rdb.verifyFilters(filTab, noisy)
    xCheck verifyFiltersOk

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
