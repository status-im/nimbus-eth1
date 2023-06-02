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
  eth/common,
  stew/results,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_desc, aristo_debug, aristo_error, aristo_get, aristo_hashify,
    aristo_hike, aristo_merge],
  ../../nimbus/sync/snap/range_desc,
  ./test_helpers

type
  KnownHasherFailure* = seq[(string,(VertexID,AristoError))]
    ## (<sample-name> & "#" <instance>, @[(<slot-id>, <error-symbol>)), ..])

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc pp(w: tuple[merged: int, dups: int, error: AristoError]): string =
    result = "(merged: " & $w.merged & ", dups: " & $w.dups
    if w.error != AristoError(0):
      result &= ", error: " & $w.error
    result &= ")"

proc mergeStepwise(
    db: AristoDbRef;
    leafs: openArray[LeafKVP];
    noisy: bool;
      ): tuple[merged: int, dups: int, error: AristoError] =
  let
    lTabLen = db.lTab.len
  var
    (merged, dups, error) = (0, 0, AristoError(0))

  for n,leaf in leafs:
    var
      event = false # or (2 < u) or true
      dumpOk = false or event
      stopOk = false
    let
      preState = db.pp
      hike = db.merge leaf
      ekih = leaf.pathTag.hikeUp(db.lRoot, db)

    case hike.error:
    of AristoError(0):
      merged.inc
    of MergeLeafPathCachedAlready:
      dups.inc
    else:
      error = hike.error
      dumpOk = true
      stopOk = true

    if ekih.error != AristoError(0):
      dumpOk = true
      stopOk = true

    let hashesOk = block:
      let rc = db.hashifyCheck(relax = true)
      if rc.isOk:
        (VertexID(0),AristoError(0))
      else:
        dumpOk = true
        stopOk = true
        if error == AristoError(0):
          error = rc.error[1]
        rc.error

    if dumpOk:
      noisy.say "***", "<", n, "/", leafs.len-1, "> ", leaf.pathTag.pp,
        "\n   pre-state ", preState,
        "\n   --------",
        "\n   merge => hike",
        "\n    ", hike.pp(db),
        "\n   --------",
        "\n    ekih", ekih.pp(db),
        "\n   --------",
        "\n   post-state ", db.pp,
        "\n"

    check hike.error in {AristoError(0), MergeLeafPathCachedAlready}
    check ekih.error == AristoError(0)
    check hashesOk == (VertexID(0),AristoError(0))

    if ekih.legs.len == 0:
      check 0 < ekih.legs.len
    elif ekih.legs[^1].wp.vtx.vType != Leaf:
      check ekih.legs[^1].wp.vtx.vType == Leaf
    elif hike.error != MergeLeafPathCachedAlready:
      check ekih.legs[^1].wp.vtx.lData.blob == leaf.payload.blob

    if db.lTab.len != lTabLen + merged:
      error = GenericError
      check db.lTab.len == lTabLen + merged # quick leaf access table
      stopOk = true                         # makes no sense to go on further

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
    resetDb = false;
      ) =
  var db = AristoDbRef()
  for n,w in list:
    if resetDb:
      db = AristoDbRef()
    let
      lstLen = list.len
      lTabLen = db.lTab.len
      leafs = w.kvpLst
      #prePreDb = db.pp
      added = db.merge leafs
      #added = db.mergeStepwise(leafs, noisy=(6 < n))

    check added.error == AristoError(0)
    check db.lTab.len == lTabLen + added.merged
    check added.merged + added.dups == leafs.len

    let
      #preDb = db.pp
      preKMap = (db.kMap.len, db.pp(sTabOk=false, lTabOk=false))
      prePAmk = (db.pAmk.len, db.pAmk.pp(db))

    block:
      let rc = db.hashify # (noisy=true)
      if rc.isErr: # or true:
        noisy.say "***", "<", n, ">",
         " added=", added,
         " db dump",
          "\n   pre-kMap(", preKMap[0], ")\n    ", preKMap[1],
          #"\n   pre-pre-DB", prePreDb, "\n   --------\n   pre-DB", preDb,
          "\n   --------",
          "\n   post-state ", db.pp,
          "\n"
      if rc.isErr:
        check rc.error == (VertexID(0),AristoError(0)) # force message
        return

    block:
      let rc = db.hashifyCheck()
      if rc.isErr:
        noisy.say "***", "<", n, "/", lstLen-1, "> db dump",
          "\n   pre-kMap(", preKMap[0], ")\n    ", preKMap[1],
          "\n   --------",
          "\n   pre-pAmk(", prePAmk[0], ")\n    ", prePAmk[1],
          "\n   --------",
          "\n   post-state ", db.pp,
          "\n"
      if rc.isErr:
        check rc == Result[void,(VertexID,AristoError)].ok()
        return

    when true and false:
      noisy.say "***", "sample ", n, "/", lstLen-1,
        " leafs merged=", added.merged,
        " dup=", added.dups


proc test_mergeProofAndKvpList*(
    noisy: bool;
    list: openArray[ProofTrieData];
    resetDb = false;
    idPfx = "";
    oops: KnownHasherFailure = @[];
      ) =
  var
    db = AristoDbRef(nil)
    rootKey = NodeKey.default
    count = 0
  for n,w in list:
    if resetDb  or w.root != rootKey or w.proof.len == 0:
      db = AristoDbRef()
      rootKey = w.root
      count = 0
    count.inc

    let
      testId = idPfx & "#" & $w.id & "." & $n
      oopsTab = oops.toTable
      lstLen = list.len
      sTabLen = db.sTab.len
      lTabLen = db.lTab.len
      leafs = w.kvpLst

    when true and false:
      noisy.say "***", "sample <", n, "/", lstLen-1, ">",
        " groups=", count, " nLeafs=", leafs.len

    var proved: tuple[merged: int, dups: int, error: AristoError]
    if 0 < w.proof.len:
      proved = db.merge w.proof
      check proved.error in {AristoError(0),MergeNodeKeyCachedAlready}
      check w.proof.len == proved.merged + proved.dups
      check db.lTab.len == lTabLen
      check db.sTab.len == proved.merged + sTabLen
      check proved.merged < db.pAmk.len
      check proved.merged < db.kMap.len

      # Set up root ID
      db.lRoot = db.pAmk.getOrDefault(rootKey, VertexID(0))
      if db.lRoot == VertexID(0):
        check db.lRoot != VertexID(0)
        return

    when true and false:
      noisy.say "***", "sample <", n, "/", lstLen-1, ">",
        " groups=", count, " nLeafs=", leafs.len, " proved=", proved

    let
      merged = db.merge leafs
      #merged = db.mergeStepwise(leafs, noisy=false)

    check db.lTab.len == lTabLen + merged.merged
    check merged.merged + merged.dups == leafs.len

    if w.proof.len == 0:
      let vtx = db.getVtx VertexID(1)
      #check db.pAmk.getOrDefault(rootKey, VertexID(0)) != VertexID(0)

    block:
      if merged.error notin {AristoError(0), MergeLeafPathCachedAlready}:
        noisy.say "***", "<", n, "/", lstLen-1, ">\n   ", db.pp
        check merged.error in {AristoError(0), MergeLeafPathCachedAlready}
        return

    #noisy.say "***", "sample ", n, "/", lstLen-1, " merged=", merged

    block:
      let
        preRoot = db.lRoot
        preDb = db.pp(sTabOk=false, lTabOk=false)
        rc = db.hashify rootKey

      # Handle known errors
      if oopsTab.hasKey(testId):
        if rc.isOK:
          check rc.isErr
          return
        if oopsTab[testId] != rc.error:
          check oopsTab[testId] == rc.error
          return

      # Otherwise, check for correctness
      elif rc.isErr:
        noisy.say "***", "<", n, "/", lstLen-1, ">",
          " testId=", testId,
          " groups=", count,
          "\n   pre-DB",
          " lRoot=", preRoot.pp,
          "\n   ", preDb,
          "\n   --------",
          "\n   ", db.pp
        check rc.error == (VertexID(0),AristoError(0))
        return

    if db.lRoot == VertexID(0):
      check db.lRoot != VertexID(0)
      return

    when true and false:
      noisy.say "***", "sample <", n, "/", lstLen-1, ">",
        " groups=", count, " proved=", proved.pp, " merged=", merged.pp

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
