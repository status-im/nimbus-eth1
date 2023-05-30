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
  std/sequtils,
  eth/common,
  stew/results,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_desc, aristo_debug, aristo_error, aristo_hashify,
    aristo_hike, aristo_merge],
  ../../nimbus/sync/snap/range_desc,
  ../replay/undump_accounts,
  ./test_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

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
    else:
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

proc test_mergeAccounts*(
    noisy: bool;
    lst: openArray[UndumpAccounts];
      ) =
  let
    db = AristoDbRef()

  for n,par in lst:
    let
      lTabLen = db.lTab.len
      leafs = par.data.accounts.to(seq[LeafKVP])
      added = db.merge leafs
      #added = db.mergeStepwise(leafs, noisy=false)

    check added.error == AristoError(0)
    check db.lTab.len == lTabLen + added.merged
    check added.merged + added.dups == leafs.len

    let
      preKMap = (db.kMap.len, db.pp(sTabOk=false, lTabOk=false))
      prePAmk = (db.pAmk.len, db.pAmk.pp(db))

    block:
      let rc = db.hashify # (noisy=true)
      if rc.isErr: # or true:
        noisy.say "***", "<", n, "> db dump",
          "\n   pre-kMap(", preKMap[0], ")\n    ", preKMap[1],
          "\n   --------",
          "\n   post-state ", db.pp,
          "\n"
      if rc.isErr:
        check rc.error == (VertexID(0),AristoError(0)) # force message
        return

    block:
      let rc = db.hashifyCheck()
      if rc.isErr:
        noisy.say "***", "<", n, "/", lst.len-1, "> db dump",
          "\n   pre-kMap(", preKMap[0], ")\n    ", preKMap[1],
          "\n   --------",
          "\n   pre-pAmk(", prePAmk[0], ")\n    ", prePAmk[1],
          "\n   --------",
          "\n   post-state ", db.pp,
          "\n"
      if rc.isErr:
        check rc == Result[void,(VertexID,AristoError)].ok()
        return

    #noisy.say "***", "sample ",n,"/",lst.len-1," leafs merged: ", added.merged


proc test_mergeProofsAndAccounts*(
    noisy: bool;
    lst: openArray[UndumpAccounts];
      ) =
  let
    db = AristoDbRef()

  for n,par in lst:
    let
      sTabLen = db.sTab.len
      lTabLen = db.lTab.len
      leafs = par.data.accounts.to(seq[LeafKVP])

    #noisy.say "***", "sample ",n,"/",lst.len-1, " start, nLeafs=", leafs.len

    let
      rootKey = par.root.to(NodeKey)
      proved = db.merge par.data.proof

    check proved.error in {AristoError(0),MergeNodeKeyCachedAlready}
    check par.data.proof.len == proved.merged + proved.dups
    check db.lTab.len == lTabLen
    check db.sTab.len == proved.merged + sTabLen
    check proved.merged < db.pAmk.len
    check proved.merged < db.kMap.len

    # Set up root ID
    db.lRoot = db.pAmk.getOrDefault(rootKey, VertexID(0))
    check db.lRoot != VertexID(0)

    #noisy.say "***", "sample ", n, "/", lst.len-1, " proved=", proved
    #noisy.say "***", "<", n, "/", lst.len-1, ">\n   ", db.pp

    let
      added = db.merge leafs
      #added = db.mergeStepwise(leafs, noisy=false)

    check db.lTab.len == lTabLen + added.merged
    check added.merged + added.dups == leafs.len

    block:
      if added.error notin {AristoError(0), MergeLeafPathCachedAlready}:
        noisy.say "***", "<", n, "/", lst.len-1, ">\n   ", db.pp
        check added.error in {AristoError(0), MergeLeafPathCachedAlready}
        return

    #noisy.say "***", "sample ", n, "/", lst.len-1, " added=", added

    block:
      let rc = db.hashify # (noisy=false or (7 <= n))
      if rc.isErr:
        noisy.say "***", "<", n, "/", lst.len-1, ">\n   ", db.pp
        check rc.error == (VertexID(0),AristoError(0))
        return

    #noisy.say "***", "sample ",n,"/",lst.len-1," leafs merged: ", added.merged

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
