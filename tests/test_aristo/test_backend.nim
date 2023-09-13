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
  std/[algorithm, hashes, sequtils, sets, strutils, tables],
  eth/common,
  results,
  unittest2,
  stew/endians2,
  ../../nimbus/sync/protocol,
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/[
    aristo_debug,
    aristo_desc,
    aristo_desc/desc_backend,
    aristo_hashify,
    aristo_init/memory_db,
    aristo_init/rocks_db,
    aristo_persistent,
    aristo_transcode,
    aristo_vid],
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
    h = h !& filter.src.ByteArray32.hash
    h = h !& filter.trg.ByteArray32.hash

    for w in filter.vGen.vidReorg:
      h = h !& w.uint64.hash

    for w in filter.sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
      let data = filter.sTab.getOrVoid(w).blobify.get(otherwise = EmptyBlob)
      h = h !& (w.uint64.toBytesBE.toSeq & data).hash

    for w in filter.kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
      let data = filter.kMap.getOrVoid(w).ByteArray32.toSeq
      h = h !& (w.uint64.toBytesBE.toSeq & data).hash

  !$h

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc mergeData(
    db: AristoDbRef;
    rootKey: HashKey;
    rootVid: VertexID;
    proof: openArray[SnapProof];
    leafs: openArray[LeafTiePayload];
    noisy: bool;
      ): bool =
  ## Simplified loop body of `test_mergeProofAndKvpList()`
  if 0 < proof.len:
    let rc = db.merge(rootKey, rootVid)
    xCheckRc rc.error == 0

    let proved = db.merge(proof, rc.value)
    xCheck proved.error in {AristoError(0),MergeHashKeyCachedAlready}

  let merged = db.merge leafs
  xCheck merged.error in {AristoError(0), MergeLeafPathCachedAlready}

  block:
    let rc = db.hashify # (noisy, true)
    xCheckRc rc.error == (0,0):
      noisy.say "***", "dataMerge(9)",
        " nLeafs=", leafs.len,
        "\n    cache dump\n    ", db.pp,
        "\n    backend dump\n    ", db.backend.pp(db)

  true

proc verify(
    ly: LayerRef;                            # Database layer
    be: MemBackendRef|RdbBackendRef;         # Backend
    noisy: bool;
      ): bool =
  ## ..

  let
    beSTab = be.walkVtx.toSeq.mapIt((it[1],it[2])).toTable
    beKMap = be.walkKey.toSeq.mapIt((it[1],it[2])).toTable

  for vid in beSTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let
      nVtx = ly.sTab.getOrVoid vid
      mVtx = beSTab.getOrVoid vid

    xCheck (nVtx != VertexRef(nil))
    xCheck (mVtx != VertexRef(nil))
    xCheck nVtx == mVtx:
      noisy.say "***", "verify",
        " beType=", be.typeof,
        " vid=", vid.pp,
        " nVtx=", nVtx.pp,
        " mVtx=", mVtx.pp

    xCheck beSTab.len == ly.sTab.len
    xCheck beKMap.len == ly.kMap.len

  true

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

proc verifyFiltersImpl[T](
    be: T;
    tab: Table[QueueID,Hash];
    noisy: bool;
      ): bool =
  ## Compare stored filters against registered ones
  var n = 0
  for (_,fid,filter) in be.walkFilBe:
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

proc verifyFilters(
    db: AristoDbRef;
    tab: Table[QueueID,Hash];
    noisy: bool;
      ): bool =
  ## Wrapper
  case db.backend.kind:
  of BackendMemory:
    return db.to(MemBackendRef).verifyFiltersImpl(tab, noisy)
  of BackendRocksDB:
    return db.to(RdbBackendRef).verifyFiltersImpl(tab, noisy)
  else:
    discard
  check db.backend.kind == BackendMemory or db.backend.kind == BackendRocksDB

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testBackendConsistency*(
    noisy: bool;
    list: openArray[ProofTrieData];          # Test data
    rdbPath: string;                         # Rocks DB storage directory
    resetDb = false;
    doRdbOk = true;
      ): bool =
  ## Import accounts
  var
    filTab: Table[QueueID,Hash]             # Filter register
    ndb = AristoDbRef()                      # Reference cache
    mdb = AristoDbRef()                      # Memory backend database
    rdb = AristoDbRef()                      # Rocks DB backend database
    rootKey = HashKey.default
    count = 0

  defer:
    rdb.finish(flush=true)

  xCheck rdbPath != ""

  for n,w in list:
    if w.root != rootKey or resetDB:
      rootKey = w.root
      count = 0
      ndb = newAristoDbRef BackendVoid
      mdb = newAristoDbRef BackendMemory

      if doRdbOk:
        if not rdb.backend.isNil: # ignore bootstrap
          let verifyFiltersOk = rdb.verifyFilters(filTab, noisy)
          xCheck verifyFiltersOk
          filTab.clear
        rdb.finish(flush=true)
        let rc = newAristoDbRef(BackendRocksDB, rdbPath)
        xCheckRc rc.error == 0
        rdb = rc.value

        # Disable automated filter management, still allow filter table access
        # for low level read/write testing.
        rdb.backend.filters = QidSchedRef(nil)
    count.inc

    xCheck ndb.backend.isNil
    xCheck not mdb.backend.isNil
    xCheck doRdbOk or not rdb.backend.isNil

    when true and false:
      noisy.say "***", "beCon(1) <", n, "/", list.len-1, ">", " groups=", count

    block:
      let
        rootVid = VertexID(1)
        leafs = w.kvpLst.mapRootVid VertexID(1) # for merging it into main trie

      block:
        let ndbOk = ndb.mergeData(
          rootKey, rootVid, w.proof, leafs, noisy=false)
        xCheck ndbOk
      block:
        let mdbOk = mdb.mergeData(
          rootKey, rootVid, w.proof, leafs, noisy=false)
        xCheck mdbOk
      if doRdbOk: # optional
        let rdbOk = rdb.mergeData(
          rootKey, rootVid, w.proof, leafs, noisy=false)
        xCheck rdbOk

      when true and false:
        noisy.say "***", "beCon(2) <", n, "/", list.len-1, ">",
          " groups=", count,
          "\n    cache dump\n    ", ndb.pp,
          "\n    backend dump\n    ", ndb.backend.pp(ndb),
          "\n    -------------",
          "\n    mdb cache\n    ", mdb.pp,
          "\n    mdb backend\n    ", mdb.backend.pp(ndb),
          "\n    -------------",
          "\n    rdb cache\n    ", rdb.pp,
          "\n    rdb backend\n    ", rdb.backend.pp(ndb),
          "\n    -------------"

    when true and false:
      noisy.say "***", "beCon(4) <", n, "/", list.len-1, ">", " groups=", count

    var
      mdbPreSaveCache, mdbPreSaveBackend: string
      rdbPreSaveCache, rdbPreSaveBackend: string
    when true: # and false:
      #mdbPreSaveCache = mdb.pp
      #mdbPreSaveBackend = mdb.to(MemBackendRef).pp(ndb)
      rdbPreSaveCache = rdb.pp
      rdbPreSaveBackend = rdb.to(RdbBackendRef).pp(ndb)


    # Provide filter, store filter on permanent BE, and register filter digest
    block:
      let rc = mdb.stow(persistent=false, dontHashify=true, chunkedMpt=true)
      xCheckRc rc.error == (0,0)
      let collectFilterOk = rdb.collectFilter(mdb.roFilter, filTab, noisy)
      xCheck collectFilterOk

    # Store onto backend database
    block:
      #noisy.say "***", "db-dump\n    ", mdb.pp
      let rc = mdb.stow(persistent=true, dontHashify=true, chunkedMpt=true)
      xCheckRc rc.error == (0,0)

    if doRdbOk:
      let rc = rdb.stow(persistent=true, dontHashify=true, chunkedMpt=true)
      xCheckRc rc.error == (0,0)

    block:
      let mdbVerifyOk = ndb.top.verify(mdb.to(MemBackendRef), noisy)
      xCheck mdbVerifyOk:
        when true and false:
          noisy.say "***", "beCon(4) <", n, "/", list.len-1, ">",
            " groups=", count,
            "\n    ndb cache\n    ", ndb.pp,
            "\n    ndb backend=", ndb.backend.isNil.not,
            #"\n    -------------",
            #"\n    mdb pre-save cache\n    ", mdbPreSaveCache,
            #"\n    mdb pre-save backend\n    ", mdbPreSaveBackend,
            "\n    -------------",
            "\n    mdb cache\n    ", mdb.pp,
            "\n    mdb backend\n    ", mdb.backend.pp(ndb),
            "\n    -------------"

    if doRdbOk:
      let rdbVerifyOk = ndb.top.verify(rdb.to(RdbBackendRef), noisy)
      xCheck rdbVerifyOk:
        when true and false:
          noisy.say "***", "beCon(4) <", n, "/", list.len-1, ">",
            " groups=", count,
            "\n    ndb cache\n    ", ndb.pp,
            "\n    ndb backend=", ndb.backend.isNil.not,
            "\n    -------------",
            "\n    rdb pre-save cache\n    ", rdbPreSaveCache,
            "\n    rdb pre-save backend\n    ", rdbPreSaveBackend,
            "\n    -------------",
            "\n    rdb cache\n    ", rdb.pp,
            "\n    rdb backend\n    ", rdb.backend.pp(ndb),
            #"\n    -------------",
            #"\n    mdb cache\n    ", mdb.pp,
            #"\n    mdb backend\n    ", mdb.backend.pp(ndb),
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
