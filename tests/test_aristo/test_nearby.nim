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
  std/[algorithm, sequtils, sets],
  eth/common,
  stew/results,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_desc, aristo_debug, aristo_merge, aristo_nearby],
  ./test_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc fwdWalkLeafsCompleteDB(
    db: AristoDb;
    root: VertexID;
    tags: openArray[HashID];
    noisy: bool;
      ): tuple[visited: int, error:  AristoError] =
  let
    tLen = tags.len
  var
    lty = LeafTie(root: root, path: HashID(tags[0].u256 div 2))
    n = 0
  while true:
    let rc = lty.right(db)
    #noisy.say "=================== ", n
    if rc.isErr:
      if rc.error[1] != NearbyBeyondRange:
        noisy.say "***", "[", n, "/", tLen-1, "] fwd-walk error=", rc.error
        check rc.error == (0,0)
        return (n,rc.error[1])
      if n != tLen:
        check n == tLen
        return (n,AristoError(1))
      break
    if tLen <= n:
      noisy.say "***", "[", n, "/", tLen-1, "] fwd-walk -- ",
        " oops, too many leafs (index overflow)"
      check n < tlen
      return (n,AristoError(1))
    if rc.value.path != tags[n]:
      noisy.say "***", "[", n, "/", tLen-1, "] fwd-walk -- leafs differ,",
        " got=", rc.value.pp(db),
        " wanted=", LeafTie(root: root, path: tags[n]).pp(db) #,
        # " db-dump\n    ", db.pp
      check rc.value.path == tags[n]
      return (n,AristoError(1))
    if rc.value.path < high(HashID):
      lty.path = HashID(rc.value.path.u256 + 1)
    n.inc

  (n,AristoError(0))


proc revWalkLeafsCompleteDB(
    db: AristoDb;
    root: VertexID;
    tags: openArray[HashID];
    noisy: bool;
      ): tuple[visited: int, error: AristoError] =
  let
    tLen = tags.len
  var
    delta = ((high(UInt256) - tags[^1].u256) div 2)
    lty = LeafTie(root: root, path:  HashID(tags[^1].u256 + delta))
    n = tLen-1
  while true: # and false:
    let rc = lty.left(db)
    if rc.isErr:
      if rc.error[1] != NearbyBeyondRange:
        noisy.say "***", "[", n, "/", tLen-1, "] rev-walk error=", rc.error
        check rc.error == (0,0)
        return (n,rc.error[1])
      if n != -1:
        check n == -1
        return (n,AristoError(1))
      break
    if n < 0:
      noisy.say "***", "[", n, "/", tLen-1, "] rev-walk -- ",
        " oops, too many leafs (index underflow)"
      check 0 <= n
      return (n,AristoError(1))
    if rc.value.path != tags[n]:
      noisy.say "***", "[", n, "/", tLen-1, "] rev-walk -- leafs differ,",
        " got=", rc.value.pp(db),
        " wanted=", tags[n]..pp(db) #, " db-dump\n    ", db.pp
      check rc.value.path == tags[n]
      return (n,AristoError(1))
    if low(HashID) < rc.value.path:
      lty.path = HashID(rc.value.path.u256 - 1)
    n.dec

  (tLen-1 - n, AristoError(0))

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_nearbyKvpList*(
    noisy: bool;
    list: openArray[ProofTrieData];
    resetDb = false;
      ): bool =
  var
    db: AristoDb
    rootKey = HashKey.default
    tagSet: HashSet[HashID]
    count = 0
  for n,w in list:
    if resetDb or w.root != rootKey:
      db.top = AristoLayerRef()
      rootKey = w.root
      tagSet.reset
      count = 0
    count.inc

    let
      lstLen = list.len
      lTabLen = db.top.lTab.len
      leafs = w.kvpLst.mapRootVid VertexID(1) # merge into main trie
      added = db.merge leafs

    if added.error != AristoError(0):
      check added.error == AristoError(0)
      return

    check db.top.lTab.len == lTabLen + added.merged
    check added.merged + added.dups == leafs.len

    for kvp in leafs:
      tagSet.incl kvp.leafTie.path

    let
      tags = tagSet.toSeq.sorted
      rootVid = leafs[0].leafTie.root
      fwdWalk = db.fwdWalkLeafsCompleteDB(rootVid, tags, noisy=true)
      revWalk = db.revWalkLeafsCompleteDB(rootVid, tags, noisy=true)

    check fwdWalk.error == AristoError(0)
    check revWalk.error == AristoError(0)
    check fwdWalk == revWalk

    if {fwdWalk.error, revWalk.error} != {AristoError(0)}:
      noisy.say "***", "<", n, "/", lstLen-1, ">",
       " groups=", count, " db dump",
        "\n   post-state ", db.pp,
        "\n"
      return

    #noisy.say "***", "sample ",n,"/",lstLen-1, " visited=", fwdWalk.visited

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
