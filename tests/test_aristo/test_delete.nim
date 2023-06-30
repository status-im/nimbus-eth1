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
  std/[algorithm, bitops, sequtils, strutils, sets],
  eth/common,
  stew/results,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_desc, aristo_debug, aristo_delete, aristo_get,
    aristo_hashify, aristo_hike, aristo_init, aristo_layer, aristo_nearby,
    aristo_merge],
  ./test_helpers

type
  TesterDesc = object
    prng: uint32                       ## random state

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc sortedKeys(lTab: Table[LeafTie,VertexID]): seq[LeafTie] =
  lTab.keys.toSeq.sorted(cmp = proc(a,b: LeafTie): int = cmp(a,b))

proc pp(q: HashSet[LeafTie]): string =
  "{" & q.toSeq.mapIt(it.pp).join(",") & "}"

# --------------

proc posixPrngRand(state: var uint32): byte =
  ## POSIX.1-2001 example of a rand() implementation, see manual page rand(3).
  state = state * 1103515245 + 12345;
  let val = (state shr 16) and 32767    # mod 2^31
  (val shr 8).byte                      # Extract second byte

proc rand[W: SomeInteger|VertexID](ap: var TesterDesc; T: type W): T =
  var a: array[sizeof T,byte]
  for n in 0 ..< sizeof T:
    a[n] = ap.prng.posixPrngRand().byte
  when sizeof(T) == 1:
    let w = uint8.fromBytesBE(a).T
  when sizeof(T) == 2:
    let w = uint16.fromBytesBE(a).T
  when sizeof(T) == 4:
    let w = uint32.fromBytesBE(a).T
  else:
    let w = uint64.fromBytesBE(a).T
  when T is SomeUnsignedInt:
    # That way, `fromBytesBE()` can be applied to `uint`
    result = w
  else:
    # That way the result is independent of endianness
    (addr result).copyMem(unsafeAddr w, sizeof w)

proc init(T: type TesterDesc; seed: int): TesterDesc =
  result.prng = (seed and 0x7fffffff).uint32

proc rand(td: var TesterDesc; top: int): int =
  if 0 < top:
    let mask = (1 shl (8 * sizeof(int) - top.countLeadingZeroBits)) - 1
    for _ in 0 ..< 100:
      let w = mask and td.rand(typeof(result))
      if w < top:
        return w
    raiseAssert "Not here (!)"

# -----------------------

proc randomisedLeafs(db: AristoDb; td: var TesterDesc): seq[LeafTie] =
  result = db.top.lTab.sortedKeys
  if 2 < result.len:
    for n in 0 ..< result.len-1:
      let r = n + td.rand(result.len - n)
      result[n].swap result[r]


proc saveToBackend(
    db: var AristoDb;
    relax: bool;
    noisy: bool;
    debugID: int;
      ): bool =
  let
    trigger = false # or (debugID == 340)
    prePreCache = db.pp
    prePreBe = db.to(TypedBackendRef).pp(db)
  if trigger:
    noisy.say "***", "saveToBackend =========================== ", debugID
  block:
    let rc = db.checkCache(relax=true)
    if rc.isErr:
      noisy.say "***", "saveToBackend (1) hashifyCheck",
        " debugID=", debugID,
        " error=", rc.error,
        "\n    cache\n     ", db.pp,
        "\n    backend\n    ", db.to(TypedBackendRef).pp(db),
        "\n    --------"
      check rc.error == (0,0)
      return
  block:
    let rc = db.hashify # (noisy = trigger)
    if rc.isErr:
      noisy.say "***", "saveToBackend (2) hashify",
        " debugID=", debugID,
        " error=", rc.error,
        "\n    pre-cache\n    ", prePreCache,
        "\n    pre-be\n    ", prePreBe,
        "\n    -------- hasify() -----",
        "\n    cache\n     ", db.pp,
        "\n    backend\n    ", db.to(TypedBackendRef).pp(db),
        "\n    --------"
      check rc.error == (0,0)
      return
  let
    preCache = db.pp
    preBe = db.to(TypedBackendRef).pp(db)
  block:
    let rc = db.checkBE(relax=true)
    if rc.isErr:
      let noisy = true
      noisy.say "***", "saveToBackend (3) checkBE",
        " debugID=", debugID,
        " error=", rc.error,
        "\n    cache\n    ", db.pp,
        "\n    backend\n    ", db.to(TypedBackendRef).pp(db),
        "\n    --------"
      check rc.error == (0,0)
      return
  block:
    let rc = db.save()
    if rc.isErr:
      check rc.error == (0,0)
      return
  block:
    let rc = db.checkBE(relax=relax)
    if rc.isErr:
      let noisy = true
      noisy.say "***", "saveToBackend (4) checkBE",
        " debugID=", debugID,
        " error=", rc.error,
        "\n    prePre-cache\n    ", prePreCache,
        "\n    prePre-be\n    ", prePreBe,
        "\n    -------- hashify() -----",
        "\n    pre-cache\n    ", preCache,
        "\n    pre-be\n    ", preBe,
        "\n    -------- save() --------",
        "\n    cache\n    ", db.pp,
        "\n    backend\n    ", db.to(TypedBackendRef).pp(db),
        "\n    --------"
      check rc.error == (0,0)
      return

  when true and false:
    if trigger:
      noisy.say "***", "saveToBackend (9)",
        " debugID=", debugID,
        "\n    prePre-cache\n    ", prePreCache,
        "\n    prePre-be\n    ", prePreBe,
        "\n    -------- hashify() -----",
        "\n    pre-cache\n    ", preCache,
        "\n    pre-be\n    ", preBe,
        "\n    -------- save() --------",
        "\n    cache\n    ", db.pp,
        "\n    backend\n    ", db.to(TypedBackendRef).pp(db),
        "\n    --------"
  true


proc fwdWalkVerify(
    db: AristoDb;
    root: VertexID;
    left: HashSet[LeafTie];
    noisy: bool;
    debugID: int;
      ): tuple[visited: int, error: AristoError] =
  let
    nLeafs = left.len
  var
    lfLeft = left
    lty = LeafTie(root: root)
    n = 0

  while n < nLeafs + 1:
    let id = n + (nLeafs + 1) * debugID
    noisy.say "NearbyBeyondRange =================== ", id

    let rc = lty.right db
    if rc.isErr:
      if rc.error[1] != NearbyBeyondRange or 0 < lfLeft.len:
        noisy.say "***", "fwdWalkVerify (1) nearbyRight",
          " n=", n, "/",  nLeafs,
          " lty=", lty.pp(db),
          " error=", rc.error
        check rc.error == (0,0)
        return (n,rc.error[1])
      return (0, AristoError(0))

    if rc.value notin lfLeft:
      noisy.say "***", "fwdWalkVerify (2) lfLeft",
        " n=", n, "/",  nLeafs,
        " lty=", lty.pp(db)
      check rc.error == (0,0)
      return (n,rc.error[1])

    if rc.value.path < high(HashID):
      lty.path = HashID(rc.value.path.u256 + 1)

    lfLeft.excl rc.value
    n.inc

  noisy.say "***", "fwdWalkVerify (9) oops",
    " n=", n, "/", nLeafs,
    " lfLeft=", lfLeft.pp
  check n <= nLeafs
  (-1, AristoError(1))

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_delete*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                          # Rocks DB storage directory
       ): bool =
  var
    td = TesterDesc.init 42
    db: AristoDb
  defer:
    db.finish(flush=true)

  for n,w in list:
    # Start with new database
    db.finish(flush=true)
    db = block:
      let rc = AristoDb.init(BackendRocksDB,rdbPath)
      if rc.isErr:
        check rc.error == 0
        return
      rc.value

    # Merge leaf data into main trie (w/vertex ID 1)
    let
      leafs = w.kvpLst.mapRootVid VertexID(1)
      added = db.merge leafs
    if added.error != 0:
      check added.error == 0
      return

    # Provide a (reproducible) peudo-random copy of the leafs list
    let leafTies = db.randomisedLeafs td
    var leafsLeft = leafs.mapIt(it.leafTie).toHashSet

    # Complete as `Merkle Patricia Tree` and save to backend, clears cache
    block:
      let saveBeOk = db.saveToBackend(relax=true, noisy=false, 0)
      if not saveBeOk:
        check saveBeOk
        return

    # Trigger subsequent saving tasks in loop below
    let (saveMod, saveRest, relax) = block:
      if leafTies.len < 17:    (7, 3, false)
      elif leafTies.len < 31: (11, 7, false)
      else:   (leafTies.len div 5, 11, true)

    # Loop over leaf ties
    for u,leafTie in leafTies:

      # Get leaf vertex ID so making sure that it is on the database
      let
        runID = n + list.len * u
        doSaveBeOk = ((u mod saveMod) == saveRest) # or true
        trigger = false # or runID in {60,80}
        tailWalkVerify = 20 # + 999
        leafVid = block:
          let hike = leafTie.hikeUp(db)
          if hike.error !=  0:                     # Ooops
            check hike.error == 0
            return
          hike.legs[^1].wp.vid

      if doSaveBeOk:
        when true and false:
          noisy.say "***", "del(1)",
            " n=", n, "/", list.len,
            " u=", u, "/", leafTies.len,
            " runID=", runID,
            " relax=", relax,
            " leafVid=", leafVid.pp
        let saveBeOk = db.saveToBackend(relax=relax, noisy=noisy, runID)
        if not saveBeOk:
          noisy.say "***", "del(2)",
           " n=", n, "/", list.len,
           " u=", u, "/", leafTies.len,
           " leafVid=", leafVid.pp
          check saveBeOk
          return

      # Delete leaf
      let
        preCache = db.pp
        rc = db.delete leafTie
      if rc.isErr:
        check rc.error == (0,0)
        return

      # Update list of remaininf leafs
      leafsLeft.excl leafTie

      let leafVtx = db.getVtx leafVid
      if leafVtx.isValid:
        noisy.say "***", "del(3)",
          " n=", n, "/", list.len,
          " u=", u, "/", leafTies.len,
          " runID=", runID,
          " root=", leafTie.root.pp,
          " leafVid=", leafVid.pp,
          "\n    --------",
          "\n    pre-cache\n    ", preCache,
          "\n    --------",
          "\n    cache\n    ", db.pp,
          "\n    backend\n    ", db.to(TypedBackendRef).pp(db),
          "\n    --------"
        check leafVtx.isValid == false
        return

      # Walking the database is too slow for large tables. So the hope is that
      # potential errors will not go away and rather pop up later, as well.
      if leafsLeft.len <= tailWalkVerify:
        if u < leafTies.len-1:
          let
            noisy = false
            vfy = db.fwdWalkVerify(leafTie.root, leafsLeft, noisy, runID)
          if vfy.error != AristoError(0): # or 7 <= u:
            noisy.say "***", "del(5)",
              " n=", n, "/", list.len,
              " u=", u, "/", leafTies.len,
              " runID=", runID,
              " root=", leafTie.root.pp,
              " leafVid=", leafVid.pp,
              "\n    leafVtx=", leafVtx.pp(db),
              "\n    --------",
              "\n    pre-cache\n    ", preCache,
              "\n    -------- delete() -------",
              "\n    cache\n    ", db.pp,
              "\n    backend\n    ", db.to(TypedBackendRef).pp(db),
              "\n    --------"
            check vfy == (0,0)
            return

      when true and false:
        if trigger:
          noisy.say "***", "del(8)",
           " n=", n, "/", list.len,
           " u=", u, "/", leafTies.len,
           " runID=", runID,
           "\n    pre-cache\n    ", preCache,
           "\n    -------- delete() -------",
           "\n    cache\n    ", db.pp,
           "\n    backend\n    ", db.to(TypedBackendRef).pp(db),
           "\n    --------"

    when true: # and false:
      noisy.say "***", "del(9) n=", n, "/", list.len, " nLeafs=", leafs.len

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
