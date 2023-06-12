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
  stew/results,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_desc, aristo_debug, aristo_get, aristo_hashify,
    aristo_hike, aristo_merge],
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
    noisy: bool;
      ): tuple[merged: int, dups: int, error: AristoError] =
  let
    lTabLen = db.top.lTab.len
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
      ekih = leaf.leafTie.hikeUp(db)

    noisy.say "***", "step <", n, "/", leafs.len-1, "> "

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
      noisy.say "***", "<", n, "/", leafs.len-1, "> ", leaf.leafTie.pp,
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

    if db.top.lTab.len != lTabLen + merged:
      error = GenericError
      check db.top.lTab.len == lTabLen + merged # quick leaf access table
      stopOk = true                             # makes no sense to go on

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
      ): bool =

  var db = AristoDb(top: AristoLayerRef())
  for n,w in list:
    if resetDb:
      db.top = AristoLayerRef()
    let
      lstLen = list.len
      lTabLen = db.top.lTab.len
      leafs = w.kvpLst.mapRootVid VertexID(1) # merge into main trie
      #prePreDb = db.pp
      added = db.merge leafs
      #added = db.mergeStepwise(leafs, noisy=true)

    check added.error == AristoError(0)
    check db.top.lTab.len == lTabLen + added.merged
    check added.merged + added.dups == leafs.len

    let
      #preDb = db.pp
      preKMap = (db.top.kMap.len, db.pp(sTabOk=false, lTabOk=false))
      prePAmk = (db.top.pAmk.len, db.top.pAmk.pp(db))

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
        " merged=", added.merged,
        " dup=", added.dups
  true


proc test_mergeProofAndKvpList*(
    noisy: bool;
    list: openArray[ProofTrieData];
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
  for n,w in list:
    if resetDb or w.root != rootKey or w.proof.len == 0:
      db.top = AristoLayerRef()
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
      noisy.say "***", "sample(1) <", n, "/", lstLen-1, ">",
        " groups=", count, " nLeafs=", leafs.len,
        " db-dump\n   ", db.pp

    var proved: tuple[merged: int, dups: int, error: AristoError]
    if 0 < w.proof.len:
      let rc = db.merge(rootKey, VertexID(1))
      if rc.isErr:
        check rc.error == AristoError(0)
        return
      proved = db.merge(w.proof, rc.value)
      check proved.error in {AristoError(0),MergeHashKeyCachedAlready}
      check w.proof.len == proved.merged + proved.dups
      check db.top.lTab.len == lTabLen
      check db.top.sTab.len == proved.merged + sTabLen
      check proved.merged < db.top.pAmk.len
      check proved.merged < db.top.kMap.len

    when true and false:
      if 0 < w.proof.len:
        noisy.say "***", "sample(2) <", n, "/", lstLen-1, ">",
          " groups=", count, " nLeafs=", leafs.len, " proved=", proved,
          " db-dump\n   ", db.pp

    let
      merged = db.merge leafs
      #merged = db.mergeStepwise(leafs, noisy=false)

    check db.top.lTab.len == lTabLen + merged.merged
    check merged.merged + merged.dups == leafs.len

    if w.proof.len == 0:
      let vtx = db.getVtx VertexID(1)

    block:
      if merged.error notin {AristoError(0), MergeLeafPathCachedAlready}:
        noisy.say "***", "<", n, "/", lstLen-1, ">\n   ", db.pp
        check merged.error in {AristoError(0), MergeLeafPathCachedAlready}
        return

    when true and false:
      noisy.say "***", "sample(3) <", n, "/", lstLen-1, ">",
        " groups=", count, " nLeafs=", leafs.len, " merged=", merged,
        " db-dump\n   ", db.pp

    block:
      let
        preDb = db.pp(sTabOk=false, lTabOk=false)
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
        noisy.say "***", "<", n, "/", lstLen-1, ">",
          " testId=", testId,
          " groups=", count,
          "\n   pre-DB",
          "\n   ", preDb,
          "\n   --------",
          "\n   ", db.pp
        check rc.error == (VertexID(0),AristoError(0))
        return

    when true and false:
      noisy.say "***", "sample(4) <", n, "/", lstLen-1, ">",
        " groups=", count,
        " db-dump\n   ", db.pp

    when true and false:
      noisy.say "***", "sample(5) <", n, "/", lstLen-1, ">",
        " groups=", count, " proved=", proved.pp, " merged=", merged.pp
  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
