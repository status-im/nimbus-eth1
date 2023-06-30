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
  std/[algorithm, bitops, sequtils],
  eth/common,
  stew/results,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_desc, aristo_debug, aristo_delete, aristo_hashify,
    aristo_init, aristo_nearby, aristo_merge],
  ./test_helpers

type
  TesterDesc = object
    prng: uint32                       ## random state

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc sortedKeys(lTab: Table[LeafTie,VertexID]): seq[LeafTie] =
  lTab.keys.toSeq.sorted(cmp = proc(a,b: LeafTie): int = cmp(a,b))

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

proc fwdWalkVerify(
    db: AristoDb;
    root: VertexID;
    noisy: bool;
      ): tuple[visited: int, error:  AristoError] =
  let
    lTabLen = db.top.lTab.len
  var
    error = AristoError(0)
    lty = LeafTie(root: root)
    n = 0
  while n < lTabLen + 1:
    let rc = lty.right(db)
    #noisy.say "=================== ", n
    if rc.isErr:
      if rc.error[1] != NearbyBeyondRange:
        noisy.say "***", "<", n, "/", lTabLen-1, "> fwd-walk error=", rc.error
        error = rc.error[1]
        check rc.error == (0,0)
      break
    if rc.value.path < high(HashID):
      lty.path = HashID(rc.value.path.u256 + 1)
    n.inc

  if error != AristoError(0):
    return (n,error)

  if n != lTabLen:
    check n == lTabLen
    return (-1, AristoError(1))

  (0, AristoError(0))

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_delete*(
    noisy: bool;
    list: openArray[ProofTrieData];
      ): bool =
  var td = TesterDesc.init 42
  for n,w in list:
    let
      db = AristoDb.init BackendNone # (top: AristoLayerRef())
      lstLen = list.len
      leafs = w.kvpLst.mapRootVid VertexID(1) # merge into main trie
      added = db.merge leafs
      preState = db.pp

    if added.error != AristoError(0):
      check added.error == AristoError(0)
      return

    let rc = db.hashify
    if rc.isErr:
      check rc.error == (VertexID(0),AristoError(0))
      return
    # Now `db` represents a (fully labelled) `Merkle Patricia Tree`

    # Provide a (reproducible) peudo-random copy of the leafs list
    var leafTies = db.top.lTab.sortedKeys
    if 2 < leafTies.len:
      for n in 0 ..< leafTies.len-1:
        let r = n + td.rand(leafTies.len - n)
        leafTies[n].swap leafTies[r]

    let uMax = leafTies.len - 1
    for u,leafTie in leafTies:
      let rc = leafTie.delete db # ,noisy)
      if rc.isErr:
        check rc.error == (VertexID(0),AristoError(0))
        return
      if leafTie in db.top.lTab:
        check leafTie notin db.top.lTab
        return
      if uMax != db.top.lTab.len + u:
        check uMax == db.top.lTab.len + u
        return

      # Walking the database is too slow for large tables. So the hope is that
      # potential errors will not go away and rather pop up later, as well.
      const tailCheck = 999
      if uMax < u + tailCheck:
        if u < uMax:
          let vfy = db.fwdWalkVerify(leafTie.root, noisy)
          if vfy.error != AristoError(0):
            check vfy == (0, AristoError(0))
            return
        elif 0 < db.top.sTab.len:
          check db.top.sTab.len == 0
          return
        let rc = db.checkCache(relax=true) # ,noisy=true)
        if rc.isErr:
          noisy.say "***", "<", n, "/", lstLen-1, ">",
            " item=", u, "/", uMax,
            "\n    --------",
            "\n    pre-DB\n    ", preState,
            "\n    --------",
            "\n    cache\n    ", db.pp,
            "\n    --------"
          check rc.error == (VertexID(0),AristoError(0))
          return

      when true and false:
        if uMax < u + tailCheck or (u mod 777) == 3:
          noisy.say "***", "step lTab=", db.top.lTab.len

    when true and false:
      noisy.say "***", "sample <", n, "/", list.len-1, ">",
        " lstLen=", leafs.len
  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
