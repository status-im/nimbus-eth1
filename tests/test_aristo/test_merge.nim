# Nimbus - Types, data structures and shared utilities used in network sync
#
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
  std/tables,
  eth/common,
  stew/[byteutils, results],
  unittest2,
  ../../nimbus/db/aristo/aristo_init/aristo_rocksdb,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_desc, aristo_debug, aristo_get, aristo_hashify,
    aristo_init, aristo_hike, aristo_layer, aristo_merge],
  ./test_helpers

type
  KnownHasherFailure* = seq[(string,(int,AristoError))]
    ## (<sample-name> & "#" <instance>, (<vertex-id>,<error-symbol>))

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc pp(w: tuple[merged: int, dups: int, error: AristoError]): string =
    result = "(merged: " & $w.merged & ", dups: " & $w.dups
    if w.error != AristoError(0):
      result &= ", error: " & $w.error
    result &= ")"

proc mergeStepwise(
    db: AristoDb;
    leafs: openArray[LeafTiePayload];
    noisy = false;
      ): tuple[merged: int, dups: int, error: AristoError] =
  let
    lTabLen = db.top.lTab.len
  var
    (merged, dups, error) = (0, 0, AristoError(0))

  for n,leaf in leafs:
    var
      event = false
      dumpOk = false or event
      stopOk = false

    when true: # and false:
      noisy.say "***", "step <", n, "/", leafs.len-1, "> leaf=", leaf.pp(db)

    let
      preState = db.pp
      hike = db.merge leaf
      ekih = leaf.leafTie.hikeUp(db)

    case hike.error:
    of AristoError(0):
      merged.inc
    of MergeLeafPathCachedAlready:
      dups.inc
    else:
      error = hike.error
      dumpOk = true
      stopOk = true

    if ekih.error != AristoError(0) or
       ekih.legs[^1].wp.vtx.lData.blob != leaf.payload.blob:
      dumpOk = true
      stopOk = true

    let hashesOk = block:
      let rc = db.checkCache(relax=true)
      if rc.isOk:
        (VertexID(0),AristoError(0))
      else:
        dumpOk = true
        stopOk = true
        if error == AristoError(0):
          error = rc.error[1]
        rc.error

    if db.top.lTab.len < lTabLen + merged:
      dumpOk = true

    if dumpOk:
      noisy.say "***", "<", n, "/", leafs.len-1, ">",
        " merged=", merged,
        " dups=", dups,
        " leaf=", leaf.pp(db),
        "\n    --------",
        "\n    hike\n    ", hike.pp(db),
        "\n    ekih\n    ", ekih.pp(db),
        "\n    pre-DB\n    ", preState,
        "\n    --------",
        "\n    cache\n    ", db.pp,
        "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
        "\n    --------"

    check hike.error in {AristoError(0), MergeLeafPathCachedAlready}
    check ekih.error == AristoError(0)
    check hashesOk == (VertexID(0),AristoError(0))

    if ekih.legs.len == 0:
      check 0 < ekih.legs.len
    elif ekih.legs[^1].wp.vtx.vType != Leaf:
      check ekih.legs[^1].wp.vtx.vType == Leaf
    elif hike.error != MergeLeafPathCachedAlready:
      check ekih.legs[^1].wp.vtx.lData.blob.toHex == leaf.payload.blob.toHex

    if db.top.lTab.len < lTabLen + merged:
      check lTabLen + merged <= db.top.lTab.len
      error = GenericError
      stopOk = true # makes no sense to go on

    if stopOk:
      noisy.say "***", "<", n, "/", leafs.len-1, "> stop"
      break

  (merged,dups,error)

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_mergeKvpList*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                         # Rocks DB storage directory
    resetDb = false;
      ): bool =
  var
    db: AristoDb
  defer:
    db.finish(flush=true)
  for n,w in list:
    if resetDb or db.top.isNil:
      db.finish(flush=true)
      db = block:
        let rc = AristoDb.init(BackendRocksDB,rdbPath)
        if rc.isErr:
          check rc.error == AristoError(0)
          return
        rc.value
    let
      lstLen = list.len
      lTabLen = db.top.lTab.len
      leafs = w.kvpLst.mapRootVid VertexID(1) # merge into main trie

    when true and false:
      if true and 40 <= n:
        noisy.say "*** kvp(1)", "<", n, "/", lstLen-1, ">",
          " nLeafs=", leafs.len,
          "\n    cache\n    ", db.pp,
          "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
          "\n    --------"
    let
      added = db.merge leafs
      #added = db.mergeStepwise(leafs) #, noisy=40 <= n)

    if added.error != AristoError(0):
      check added.error == AristoError(0)
      return
    # There might be an extra leaf in the cache after inserting a Branch
    # which forks a previous leaf node and a new one.
    check lTabLen + added.merged <= db.top.lTab.len
    check added.merged + added.dups == leafs.len

    let
      preDb = db.pp

    block:
      let rc = db.hashify # (noisy=(0 < n))
      if rc.isErr: # or true:
        noisy.say "*** kvp(2)", "<", n, "/", lstLen-1, ">",
         " added=", added,
          "\n    pre-DB\n    ", preDb,
          "\n    --------",
          "\n    cache\n    ", db.pp,
          "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
          "\n    --------"
      if rc.isErr:
        check rc.error == (VertexID(0),AristoError(0)) # force message
        return

    when true and false:
      noisy.say "*** kvp(3)", "<", n, "/", lstLen-1, ">",
        "\n    cache\n    ", db.pp,
        "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
        "\n    --------"

    block:
      let rc = db.checkCache()
      if rc.isErr:
        noisy.say "*** kvp(4)", "<", n, "/", lstLen-1, "> db dump",
          "\n    pre-DB\n    ", preDb,
          "\n    --------",
          "\n    cache\n    ", db.pp,
          "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
          "\n    --------"
      if rc.isErr:
        check rc == Result[void,(VertexID,AristoError)].ok()
        return

    let rdbHist = block:
      let rc = db.save
      if rc.isErr:
        check rc.error == (0,0)
        return
      rc.value

    when true and false:
      noisy.say "*** kvp(5)", "<", n, "/", lstLen-1, ">",
        "\n    cache\n    ", db.pp,
        "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
        "\n    --------"

    when true and false:
      noisy.say "*** kvp(9)", "sample ", n, "/", lstLen-1,
        " merged=", added.merged,
        " dup=", added.dups
  true


proc test_mergeProofAndKvpList*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                         # Rocks DB storage directory
    resetDb = false;
    idPfx = "";
    oops: KnownHasherFailure = @[];
      ): bool =
  let
    oopsTab = oops.toTable
  var
    db: AristoDb
    rootKey = HashKey.default
    count = 0
  defer:
    db.finish(flush=true)
  for n,w in list:
    if resetDb or w.root != rootKey or w.proof.len == 0:
      db.finish(flush=true)
      db = block:
        let rc = AristoDb.init(BackendRocksDB,rdbPath)
        if rc.isErr:
          check rc.error == AristoError(0)
          return
        rc.value
      rootKey = w.root
      count = 0
    count.inc

    let
      testId = idPfx & "#" & $w.id & "." & $n
      lstLen = list.len
      sTabLen = db.top.sTab.len
      lTabLen = db.top.lTab.len
      leafs = w.kvpLst.mapRootVid VertexID(1) # merge into main trie

    when true and false:
      noisy.say "***", "proofs(1) <", n, "/", lstLen-1, ">",
        " groups=", count, " nLeafs=", leafs.len,
        "\n    cache\n    ", db.pp,
        "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
        "\n    --------"

    var
      proved: tuple[merged: int, dups: int, error: AristoError]
      preDb: string
    if 0 < w.proof.len:
      let rc = db.merge(rootKey, VertexID(1))
      if rc.isErr:
        check rc.error == AristoError(0)
        return

      preDb = db.pp
      proved = db.merge(w.proof, rc.value) # , noisy)

      check proved.error in {AristoError(0),MergeHashKeyCachedAlready}
      check w.proof.len == proved.merged + proved.dups
      check db.top.lTab.len == lTabLen
      check db.top.sTab.len <= proved.merged + sTabLen
      check proved.merged < db.top.pAmk.len

    when true and false:
      if 0 < w.proof.len:
        noisy.say "***", "proofs(2) <", n, "/", lstLen-1, ">",
          " groups=", count,
          " nLeafs=", leafs.len,
          " proved=", proved,
          "\n    pre-DB\n    ", preDb,
          "\n    --------",
          "\n    cache\n    ", db.pp,
          "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
          "\n    --------"
        return

    let
      merged = db.merge leafs
      #merged = db.mergeStepwise(leafs, noisy=false)

    check db.top.lTab.len == lTabLen + merged.merged
    check merged.merged + merged.dups == leafs.len

    block:
      if merged.error notin {AristoError(0), MergeLeafPathCachedAlready}:
        noisy.say "***", "<", n, "/", lstLen-1, ">\n   ", db.pp
        check merged.error in {AristoError(0), MergeLeafPathCachedAlready}
        return

    when true and false:
      noisy.say "***", "proofs(3) <", n, "/", lstLen-1, ">",
        " groups=", count, " nLeafs=", leafs.len, " merged=", merged,
        "\n    cache\n    ", db.pp,
        "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
        "\n    --------"

    block:
      let
        preDb = db.pp(xTabOk=false)
        rc = db.hashify() # noisy=true)

      # Handle known errors
      if oopsTab.hasKey testId:
        if rc.isOK:
          check rc.isErr
          return
        let oops = (VertexID(oopsTab[testId][0]), oopsTab[testId][1])
        if oops != rc.error:
          check oops == rc.error
          return

      # Otherwise, check for correctness
      elif rc.isErr:
        noisy.say "***", "proofs(4) <", n, "/", lstLen-1, ">",
          " testId=", testId,
          " groups=", count,
          "\n   pre-DB",
          "\n    ", preDb,
          "\n   --------",
          "\n    cache\n    ", db.pp,
          "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
          "\n    --------"
        check rc.error == (VertexID(0),AristoError(0))
        return

    let rdbHist = block:
      let rc = db.save
      if rc.isErr:
        check rc.error == (0,0)
        return
      rc.value

    when true and false:
      noisy.say "***", "proofs(5) <", n, "/", lstLen-1, ">",
        " groups=", count,
        "\n    cache\n    ", db.pp,
        "\n    backend\n    ", db.to(RdbBackendRef).pp(db),
        "\n    --------"

    when true and false:
      noisy.say "***", "proofs(6) <", n, "/", lstLen-1, ">",
        " groups=", count, " proved=", proved.pp, " merged=", merged.pp
  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
