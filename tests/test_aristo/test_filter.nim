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

## Aristo (aka Patricia) DB records distributed backend access test.
##

import
  eth/common,
  results,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_debug, aristo_desc, aristo_filter, aristo_get,
    aristo_merge],
  ../../nimbus/db/[aristo, aristo/aristo_init/persistent],
  ./test_helpers

type
  LeafTriplet = tuple
    a, b, c: seq[LeafTiePayload]

  LeafQuartet = tuple
    a, b, c, d: seq[LeafTiePayload]

  DbTriplet = object
    db1, db2, db3: AristoDbRef

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc dump(pfx: string; dx: varargs[AristoDbRef]): string =
  proc dump(db: AristoDbRef): string =
    db.pp & "\n    " & db.to(TypedBackendRef).pp(db) & "\n"
  if 0 < dx.len:
    result = "\n   "
  var
    pfx = pfx
    qfx = ""
  if pfx.len == 0:
    (pfx,qfx) = ("[","]")
  elif 1 < dx.len:
    pfx = pfx & "#"
  for n in 0 ..< dx.len:
    let n1 = n + 1
    result &= pfx
    if 1 < dx.len:
      result &= $n1
    result &= qfx & "\n    " & dx[n].dump
    if n1 < dx.len:
      result &= "   ==========\n   "

proc dump(dx: varargs[AristoDbRef]): string =
  "".dump dx

proc dump(w: DbTriplet): string =
  "db".dump(w.db1, w.db2, w.db3)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

iterator quadripartite(td: openArray[ProofTrieData]): LeafQuartet =
  ## ...
  var collect: seq[seq[LeafTiePayload]]

  for w in td:
    let lst = w.kvpLst.mapRootVid VertexID(1)

    if lst.len < 8:
      if 2 < collect.len:
        yield(collect[0], collect[1], collect[2], lst)
        collect.setLen(0)
      else:
        collect.add lst
    else:
      if collect.len == 0:
        let a = lst.len div 4
        yield(lst[0 ..< a], lst[a ..< 2*a], lst[2*a ..< 3*a], lst[3*a .. ^1])
      else:
        if collect.len == 1:
          let a = lst.len div 3
          yield(collect[0], lst[0 ..< a], lst[a ..< 2*a], lst[a .. ^1])
        elif collect.len == 2:
          let a = lst.len div 2
          yield(collect[0], collect[1], lst[0 ..< a], lst[a .. ^1])
        else:
          yield(collect[0], collect[1], collect[2], lst)
        collect.setLen(0)

proc dbTriplet(w: LeafQuartet; rdbPath: string): Result[DbTriplet,AristoError] =
  let
    db1 = block:
      let rc = newAristoDbRef(BackendRocksDB,rdbPath)
      if rc.isErr:
        check rc.error == 0
        return
      rc.value

    # Fill backend
    m0 = db1.merge w.a
    rc = db1.stow(persistent=true)

  if rc.isErr:
    check rc.error == (0,0)
    return

  let
    db2 = db1.copyCat.value
    db3 = db1.copyCat.value

    # Clause (9) from `aristo/README.md` example
    m1 = db1.merge w.b
    m2 = db2.merge w.c
    m3 = db3.merge w.d

  if m1.error == 0 and
     m2.error == 0 and
     m3.error == 0:
    return ok DbTriplet(db1: db1, db2: db2, db3: db3)

  # Failed
  db1.finish(flush=true)

  check m1.error == 0
  check m2.error == 0
  check m3.error == 0

  var error = m1.error
  if error != 0: error = m2.error
  if error != 0: error = m3.error
  err(error)


proc checkBeOk(
    dx: DbTriplet;
    relax = false;
    forceCache = false;
    noisy = true;
      ): bool =
  check not dx.db1.top.isNil
  block:
    let
      cache = if forceCache: true else: not dx.db1.top.dirty
      rc1 = dx.db1.checkBE(relax=relax, cache=cache)
    if rc1.isErr:
      noisy.say "***", "db1 check failed (do-cache=", cache, ")"
      check rc1.error == (0,0)
      return
  block:
    let
      cache = if forceCache: true else: not dx.db2.top.dirty
      rc2 = dx.db2.checkBE(relax=relax, cache=cache)
    if rc2.isErr:
      noisy.say "***", "db2 check failed (do-cache=", cache, ")"
      check rc2.error == (0,0)
      return
  block:
    let
      cache = if forceCache: true else: not dx.db3.top.dirty
      rc3 = dx.db3.checkBE(relax=relax, cache=cache)
    if rc3.isErr:
      noisy.say "***", "db3 check failed (do-cache=", cache, ")"
      check rc3.error == (0,0)
      return
  true

# ---------

proc cleanUp(dx: DbTriplet) =
  discard dx.db3.dispose
  discard dx.db2.dispose
  dx.db1.finish(flush=true)

proc eq(a, b: AristoFilterRef; db: AristoDbRef; noisy = true): bool =
  ## Verify that argument filter `a` has the same effect on the
  ## physical/unfiltered backend of `db` as argument filter `b`.
  if a.isNil:
    return b.isNil
  if b.isNil:
    return false
  if unsafeAddr(a[]) != unsafeAddr(b[]):
    if a.src != b.src or
       a.trg != b.trg or
       a.vGen != b.vGen:
      return false

    # Void entries may differ unless on physical backend
    var (aTab, bTab) = (a.sTab, b.sTab)
    if aTab.len < bTab.len:
      aTab.swap bTab
    for (vid,aVtx) in aTab.pairs:
      let bVtx = bTab.getOrVoid vid
      bTab.del vid

      if aVtx != bVtx:
        if aVtx.isValid and bVtx.isValid:
          return false
        # The valid one must match the backend data
        let rc = db.getVtxUBE vid
        if rc.isErr:
          return false
        let vtx = if aVtx.isValid: aVtx else: bVtx
        if vtx != rc.value:
          return false

      elif not vid.isValid and not bTab.hasKey vid:
        let rc = db.getVtxUBE vid
        if rc.isOk:
          return false # Exists on backend but missing on `bTab[]`
        elif rc.error != GetKeyNotFound:
          return false # general error

    if 0 < bTab.len:
      noisy.say "*** eq:", "bTabLen=", bTab.len
      return false

    # Similar for `kMap[]`
    var (aMap, bMap) = (a.kMap, b.kMap)
    if aMap.len < bMap.len:
      aMap.swap bMap
    for (vid,aKey) in aMap.pairs:
      let bKey = bMap.getOrVoid vid
      bMap.del vid

      if aKey != bKey:
        if aKey.isValid and bKey.isValid:
          return false
        # The valid one must match the backend data
        let rc = db.getKeyUBE vid
        if rc.isErr:
          return false
        let key = if aKey.isValid: aKey else: bKey
        if key != rc.value:
          return false

      elif not vid.isValid and not bMap.hasKey vid:
        let rc = db.getKeyUBE vid
        if rc.isOk:
          return false # Exists on backend but missing on `bMap[]`
        elif rc.error != GetKeyNotFound:
          return false # general error

    if 0 < bMap.len:
      noisy.say "*** eq:", " bMapLen=", bMap.len
      return false

  true

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testDistributedAccess*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                          # Rocks DB storage directory
       ): bool =
  var n = 0
  for w in list.quadripartite:
    n.inc

    # Resulting clause (11) filters from `aristo/README.md` example
    # which will be used in the second part of the tests
    var
      c11Filter1 = AristoFilterRef(nil)
      c11Filter3 = AristoFilterRef(nil)

    # Work through clauses (8)..(11) from `aristo/README.md` example
    block:

      # Clause (8) from `aristo/README.md` example
      let
        dx = block:
          let rc = dbTriplet(w, rdbPath)
          if rc.isErr:
            return
          rc.value
        (db1, db2, db3) = (dx.db1, dx.db2, dx.db3)
      defer:
        dx.cleanUp()

      when false: # or true:
        noisy.say "*** testDistributedAccess (1)", "n=", n, dx.dump

      # Clause (9) from `aristo/README.md` example
      block:
        let rc = db1.stow(persistent=true)
        if rc.isErr:
          # noisy.say "*** testDistributedAccess (2) n=", n, dx.dump
          check rc.error == (0,0)
          return
      if db1.roFilter != AristoFilterRef(nil):
        check db1.roFilter == AristoFilterRef(nil)
        return
      if db2.roFilter != db3.roFilter:
        check db2.roFilter == db3.roFilter
        return

      block:
        let rc = db2.stow(persistent=false)
        if rc.isErr:
          noisy.say "*** testDistributedAccess (3)", "n=", n, "db2".dump db2
          check rc.error == (0,0)
          return
      if db1.roFilter != AristoFilterRef(nil):
        check db1.roFilter == AristoFilterRef(nil)
        return
      if db2.roFilter == db3.roFilter:
        check db2.roFilter != db3.roFilter
        return

      # Clause (11) from `aristo/README.md` example
      block:
        let rc = db2.ackqRwMode()
        if rc.isErr:
          check rc.error == 0
          return
      block:
        let rc = db2.stow(persistent=true)
        if rc.isErr:
          check rc.error == (0,0)
          return
      if db2.roFilter != AristoFilterRef(nil):
        check db2.roFilter == AristoFilterRef(nil)
        return

      # Check/verify backends
      block:
        let ok = dx.checkBeOk(noisy=noisy)
        if not ok:
          noisy.say "*** testDistributedAccess (4)", "n=", n, "db3".dump db3
          check ok
          return

      # Capture filters from clause (11)
      c11Filter1 = db1.roFilter
      c11Filter3 = db3.roFilter

      # Clean up
      dx.cleanUp()

    # ----------

    # Work through clauses (12)..(15) from `aristo/README.md` example
    block:
      let
        dy = block:
          let rc = dbTriplet(w, rdbPath)
          if rc.isErr:
            return
          rc.value
        (db1, db2, db3) = (dy.db1, dy.db2, dy.db3)
      defer:
        dy.cleanUp()

      # Build clause (12) from `aristo/README.md` example
      block:
        let rc = db2.ackqRwMode()
        if rc.isErr:
          check rc.error == 0
          return
      block:
        let rc = db2.stow(persistent=true)
        if rc.isErr:
          check rc.error == (0,0)
          return
      if db2.roFilter != AristoFilterRef(nil):
        check db1.roFilter == AristoFilterRef(nil)
        return
      if db1.roFilter != db3.roFilter:
        check db1.roFilter == db3.roFilter
        return

      # Clause (13) from `aristo/README.md` example
      block:
        let rc = db1.stow(persistent=false)
        if rc.isErr:
          check rc.error == (0,0)
          return

      # Clause (14) from `aristo/README.md` check
      block:
        let c11Filter1_eq_db1RoFilter = c11Filter1.eq(db1.roFilter, db1, noisy)
        if not c11Filter1_eq_db1RoFilter:
          noisy.say "*** testDistributedAccess (7)", "n=", n,
            "\n   c11Filter1=", c11Filter3.pp(db1),
            "db1".dump(db1)
          check c11Filter1_eq_db1RoFilter
          return

      # Clause (15) from `aristo/README.md` check
      block:
        let c11Filter3_eq_db3RoFilter = c11Filter3.eq(db3. roFilter, db3, noisy)
        if not c11Filter3_eq_db3RoFilter:
          noisy.say "*** testDistributedAccess (8)", "n=", n,
            "\n   c11Filter3=", c11Filter3.pp(db3),
            "db3".dump(db3)
          check c11Filter3_eq_db3RoFilter
          return

      # Check/verify backends
      block:
        let ok = dy.checkBeOk(noisy=noisy)
        if not ok:
          check ok
          return

      when false: # or true:
        noisy.say "*** testDistributedAccess (9)", "n=", n, dy.dump

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
