# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  std/sets,
  eth/common,
  results,
  unittest2,
  ../../nimbus/db/opts,
  ../../nimbus/db/aristo/[
    aristo_check,
    aristo_debug,
    aristo_desc,
    aristo_get,
    aristo_layers,
    aristo_merge,
    aristo_persistent,
    aristo_tx],
  ../replay/xcheck,
  ./test_helpers

type
  LeafQuartet =
    array[0..3, seq[LeafTiePayload]]

  DbTriplet =
    array[0..2, AristoDbRef]

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc dump(pfx: string; dx: varargs[AristoDbRef]): string =
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
    result &= qfx & "\n    " & dx[n].pp(backendOk=true) & "\n"
    if n1 < dx.len:
      result &= "   ==========\n   "

when false:
  proc dump(dx: varargs[AristoDbRef]): string =
    "".dump dx

  proc dump(w: DbTriplet): string =
    "db".dump(w[0], w[1], w[2])

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
        yield [collect[0], collect[1], collect[2], lst]
        collect.setLen(0)
      else:
        collect.add lst
    else:
      if collect.len == 0:
        let a = lst.len div 4
        yield [lst[0 ..< a], lst[a ..< 2*a], lst[2*a ..< 3*a], lst[3*a .. ^1]]
      else:
        if collect.len == 1:
          let a = lst.len div 3
          yield [collect[0], lst[0 ..< a], lst[a ..< 2*a], lst[a .. ^1]]
        elif collect.len == 2:
          let a = lst.len div 2
          yield [collect[0], collect[1], lst[0 ..< a], lst[a .. ^1]]
        else:
          yield [collect[0], collect[1], collect[2], lst]
        collect.setLen(0)

proc dbTriplet(w: LeafQuartet; rdbPath: string): Result[DbTriplet,AristoError] =
  let db = block:
    if 0 < rdbPath.len:
      let rc = AristoDbRef.init(RdbBackendRef, rdbPath, DbOptions.init())
      xCheckRc rc.error == 0
      rc.value
    else:
      AristoDbRef.init MemBackendRef

  # Fill backend
  block:
    let report = db.mergeList w[0]
    if report.error != 0:
      db.finish(flush=true)
      check report.error == 0
      return err(report.error)
    let rc = db.persist()
    if rc.isErr:
      check rc.error == 0
      return

  let dx = [db, db.forkTx(0).value, db.forkTx(0).value]
  xCheck dx[0].nForked == 2

  # Reduce unwanted tx layers
  for n in 1 ..< dx.len:
    check dx[n].level == 1
    check dx[n].txTop.value.commit.isOk

  # Clause (9) from `aristo/README.md` example
  for n in 0 ..< dx.len:
    let report = dx[n].mergeList w[n+1]
    if report.error != 0:
      db.finish(flush=true)
      check (n, report.error) == (n,0)
      return err(report.error)

  return ok dx

# ----------------------

proc cleanUp(dx: var DbTriplet) =
  if not dx[0].isNil:
    dx[0].finish(flush=true)
    dx.reset

proc isDbEq(a, b: LayerDeltaRef; db: AristoDbRef; noisy = true): bool =
  ## Verify that argument filter `a` has the same effect on the
  ## physical/unfiltered backend of `db` as argument filter `b`.
  if a.isNil:
    return b.isNil
  if b.isNil:
    return false
  if unsafeAddr(a[]) != unsafeAddr(b[]):
    if a.src != b.src or
       a.kMap.getOrVoid(VertexID 1) != b.kMap.getOrVoid(VertexID 1) or
       a.vTop != b.vTop:
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
        let rc = db.getVtxUbe vid
        if rc.isErr:
          return false
        let vtx = if aVtx.isValid: aVtx else: bVtx
        if vtx != rc.value:
          return false

      elif not vid.isValid and not bTab.hasKey vid:
        let rc = db.getVtxUbe vid
        if rc.isOk:
          return false # Exists on backend but missing on `bTab[]`
        elif rc.error != GetKeyNotFound:
          return false # general error

    if 0 < bTab.len:
      noisy.say "***", "not dbEq:", "bTabLen=", bTab.len
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
        let rc = db.getKeyUbe vid
        if rc.isErr:
          return false
        let key = if aKey.isValid: aKey else: bKey
        if key != rc.value:
          return false

      elif not vid.isValid and not bMap.hasKey vid:
        let rc = db.getKeyUbe vid
        if rc.isOk:
          return false # Exists on backend but missing on `bMap[]`
        elif rc.error != GetKeyNotFound:
          return false # general error

    if 0 < bMap.len:
      noisy.say "***", "not dbEq:", " bMapLen=", bMap.len
      return false

  true

# ----------------------

proc checkBeOk(
    dx: DbTriplet;
    relax = false;
    forceCache = false;
    fifos = true;
    noisy = true;
      ): bool =
  ## ..
  for n in 0 ..< dx.len:
    let cache = if forceCache: true else: dx[n].dirty.len == 0
    block:
      let rc = dx[n].checkBE(relax=relax, cache=cache, fifos=fifos)
      xCheckRc rc.error == (0,0):
        noisy.say "***", "db checkBE failed",
          " n=", n, "/", dx.len-1,
          " cache=", cache
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
      c11Filter1 = LayerDeltaRef(nil)
      c11Filter3 = LayerDeltaRef(nil)

    # Work through clauses (8)..(11) from `aristo/README.md` example
    block:

      # Clause (8) from `aristo/README.md` example
      var
        dx = block:
          let rc = dbTriplet(w, rdbPath)
          xCheckRc rc.error == 0
          rc.value
        (db1, db2, db3) = (dx[0], dx[1], dx[2])
      defer:
        dx.cleanUp()

      when false: # or true:
        noisy.say "*** testDistributedAccess (1)", "n=", n # , dx.dump

      # Clause (9) from `aristo/README.md` example
      block:
        let rc = db1.persist()
        xCheckRc rc.error == 0
      xCheck db1.balancer == LayerDeltaRef(nil)
      xCheck db2.balancer == db3.balancer

      block:
        let rc = db2.stow() # non-persistent
        xCheckRc rc.error == 0:
          noisy.say "*** testDistributedAccess (3)", "n=", n, "db2".dump db2
      xCheck db1.balancer == LayerDeltaRef(nil)
      xCheck db2.balancer != db3.balancer

      # Clause (11) from `aristo/README.md` example
      db2.reCentre()
      block:
        let rc = db2.persist()
        xCheckRc rc.error == 0
      xCheck db2.balancer == LayerDeltaRef(nil)

      # Check/verify backends
      block:
        let ok = dx.checkBeOk(noisy=noisy,fifos=true)
        xCheck ok:
          noisy.say "*** testDistributedAccess (4)", "n=", n, "db3".dump db3

      # Capture filters from clause (11)
      c11Filter1 = db1.balancer
      c11Filter3 = db3.balancer

      # Clean up
      dx.cleanUp()

    # ----------

    # Work through clauses (12)..(15) from `aristo/README.md` example
    block:
      var
        dy = block:
          let rc = dbTriplet(w, rdbPath)
          xCheckRc rc.error == 0
          rc.value
        (db1, db2, db3) = (dy[0], dy[1], dy[2])
      defer:
        dy.cleanUp()

      # Build clause (12) from `aristo/README.md` example
      db2.reCentre()
      block:
        let rc = db2.persist()
        xCheckRc rc.error == 0
      xCheck db2.balancer == LayerDeltaRef(nil)
      xCheck db1.balancer == db3.balancer

      # Clause (13) from `aristo/README.md` example
      xCheck not db1.isCentre()
      block:
        let rc = db1.stow() # non-persistent
        xCheckRc rc.error == 0

      # Clause (14) from `aristo/README.md` check
      let c11Fil1_eq_db1RoFilter = c11Filter1.isDbEq(db1.balancer, db1, noisy)
      xCheck c11Fil1_eq_db1RoFilter:
        noisy.say "*** testDistributedAccess (7)", "n=", n,
          "\n   c11Filter1\n   ", c11Filter1.pp(db1),
          "db1".dump(db1),
          ""

      # Clause (15) from `aristo/README.md` check
      let c11Fil3_eq_db3RoFilter = c11Filter3.isDbEq(db3.balancer, db3, noisy)
      xCheck c11Fil3_eq_db3RoFilter:
        noisy.say "*** testDistributedAccess (8)", "n=", n,
          "\n   c11Filter3\n   ", c11Filter3.pp(db3),
          "db3".dump(db3),
          ""

      # Check/verify backends
      block:
        let ok = dy.checkBeOk(noisy=noisy,fifos=true)
        xCheck ok

      when false: # or true:
        noisy.say "*** testDistributedAccess (9)", "n=", n # , dy.dump

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
