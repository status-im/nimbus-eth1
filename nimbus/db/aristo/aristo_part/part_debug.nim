# nimbus-eth1
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[algorithm, sequtils, strutils, sets, typetraits],
  eth/common,
  ".."/[aristo_debug, aristo_desc, aristo_get],
  ./part_desc

export
  algorithm,
  sequtils,
  aristo_debug

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc toPfx(indent: int; offset = 0): string =
  if 0 < indent+offset: "\n" & " ".repeat(indent+offset) else: ""

proc pp(w: HashSet[HashKey]; ps: PartStateRef): string =
  "{" & w.toSeq.sorted.mapIt(it.pp(ps.db)).join(",") & "}[#" & $w.len & "]"

# ------------------------------------------------------------------------------
# Public debugging stuff
# ------------------------------------------------------------------------------

proc pp*(n: PrfNode; ps: PartStateRef): string =
  if n.isNil:
    "(nil)"
  elif n.prfType == isError:
    "(" & $n.error & ")"
  elif n.prfType == isExtension:
    "X(" & n.ePfx.pp & "," & n.key[0].pp(ps.db) & ")"
  else:
    "(" & NodeRef(n).pp(ps.db) & ")"

proc pp*(e: PrfExtension; ps: PartStateRef): string =
  if e.isNil:
    "(nil)"
  else:
    "(" & e.xPfx.pp & "," & e.xLink.pp(ps.db) & ")"

proc pp*(p: PrfPayload; ps: PartStateRef): string =
  if p.prfType == isAccount:
    p.acc.pp(ps.db)
  elif p.prfType == isStoValue:
    "(" & $p.num & ")"
  else:
    "(" & $p.error & ")"

proc pp*[T: PrfNode|PrfExtension](
    q: seq[(HashKey,T)];
    ps: PartStateRef;
    indent = 4;
      ): string =
  "{" & q.mapIt("(" & it[0].pp(ps.db) & "," & pp(it[1], ps) & ")")
         .join("," & indent.toPfx(1)) & "}"

proc pp*[T: PrfNode|PrfExtension](
    t: Table[HashKey,T];
    ps: PartStateRef;
    indent = 4;
      ): string =
  var
    t0: Table[RootedVertexID,(HashKey,T)]
    t1: Table[HashKey,T]
  for (key,val) in t.pairs:
    ps.db.xMap.withValue(key,rv):
      t0[rv[]] = (key,val)
    do:
      t1[key] = val
  let
    q0 = t0.keys.toSeq.sorted.mapIt(t0.getOrDefault it)
    q1 = t1.keys.toSeq.sorted.mapIt((it, t1.getOrDefault it))
  (q0 & q1).pp(ps,indent)

proc pp*(t: TableRef[HashKey,PrfNode]; ps: PartStateRef; indent = 4): string =
  pp(t[], ps, indent)

proc pp*(t: Table[VertexID,HashKey]; ps: PartStateRef; indent = 4): string =
  "{" & t.keys.toSeq.sorted
         .mapIt((it,t.getOrDefault it))
         .mapIt("(" & it[0].pp & "," & it[1].pp(ps.db) & ")")
         .join("," & indent.toPfx(1)) & "}"
      
proc pp*(q: seq[HashKey]; ps: PartStateRef): string =
  "(" & q.mapIt(it.pp ps.db).join("->") & ")[#" & $q.len & "]"

proc pp*(q: seq[seq[HashKey]]; ps: PartStateRef; indent = 4): string =
  "{" & q.mapIt(it.pp ps).join("," & indent.toPfx(1)) & "}"

proc pp*(x: PartStateCtx): string =
  if x.isNil:
    "ø"
  else:
    "(" & x.location.pp & "," & $x.nibble & "," & x.fromVid.pp & ")"

proc pp*(
    ps: PartStateRef;
    indent     = 4;
    # ----------
    dbOk       = true;
    coreOk     = true;
    byKeyOk    = true;
    byVidOk    = true;
    changedOk  = true;
    pureExtOk  = true;
    # ----------
    backendOk  = false;
    balancerOk = true;
    topOk      = true;
    stackOk    = true;
    kMapOk     = true;
    sTabOk     = true;
    limit      = 100;
      ): string =
  let
    pfx0 = indent.toPfx()
    pfx1 = indent.toPfx(1)
    pfx2 = indent.toPfx(2)
  var pfx = ""
  if dbOk:
    result &= pfx & "<db>" & pfx1 & ps.db.pp(
      indent     = indent + 1,
      backendOk  = backendOk,
      balancerOk = balancerOk,
      topOk      = topOk,
      stackOk    = stackOk,
      kMapOk     = kMapOk,
      sTabOk     = sTabOk,
      limit      = limit)
    pfx = pfx0
  if coreOk:
    let len = ps.core.len
    result &= pfx & "<core(" & $len & ")>"
    if 0 < len:
      var qfx = ""
      result &= pfx1 & "{"
      for vid in ps.core.keys.toSeq.sorted:
        let vLst = ps.core.getOrDefault vid
        result &= qfx & "(" & vid.pp & ":" & vLst.pp(ps) & ")"
        qfx = pfx2
      result &= "}"
    pfx = pfx0
  if byKeyOk:
    let len = ps.byKey.len
    result &= pfx & "<byKey(" & $len & ")>"
    if 0 < len:
      result &= pfx1 & ps.byKey.pp(ps.db, indent+1)
    pfx = pfx0
  if byVidOk:
    let len = ps.byVid.len
    result &= pfx & "<byVid(" & $len & ")>"
    if 0 < len:
      result &= pfx1 & ps.byVid.pp(ps, indent+1)
    pfx = pfx0
  if changedOk:
    let len = ps.changed.len
    result &= pfx & "<changed(" & $len & ")>"
    if 0 < len:
      result &= pfx1 & ps.changed.pp(ps)
    pfx = pfx0
  if pureExtOk:
    let len = ps.pureExt.len
    result &= pfx & "<pureExt(" & $len & ")>"
    if 0 < len:
      result &= pfx1 & pp[PrfExtension](ps.pureExt, ps, indent+1)
    pfx = pfx0

# ------------------

proc check*(ps: PartStateRef): Result[void,(VertexID,AristoError)] =
  # Provide temporary lookup table
  var
    byVid: ptr Table[VertexID,HashKey]
    t: Table[VertexID,HashKey] # use it in case `ps.byVid[]` is empty

  # Lookup tables must match unless `ps.byVid[]` is empty
  if ps.byVid.len == 0:
    # Create ad-hoc table
    for (key,rvid) in ps.byKey.pairs:
      t[rvid.vid] = key
    byVid = addr t
  else:
    if ps.byKey.len != ps.byVid.len:
      return err((VertexID(0),PartChkVidKeyTabLengthsDiffer))
    for (key,rvid) in ps.byKey.pairs:
      ps.byVid.withValue(rvid.vid,vKey):
        if key != vKey[]:
          return err((rvid.vid,PartChkVidKeyTabKeyMismatch))
        continue
      return err((rvid.vid,PartChkVidTabVidMissing))
    # Provide ad-hoc table
    byVid = addr ps.byVid

  # All `changed` keys must be listed in the `ps.byKey[]` tab and
  # exist on the database
  for key in ps.changed:
    ps.byKey.withValue(key,rvid):
      if not ps.db.getVtx(rvid[]).isValid:
        return err((rvid.vid,PartChkChangedVtxMissing))
      continue
    return err((VertexID(0),PartChkChangedKeyNotInKeyTab))

  # All vertices for `core` keys must exist on database
  for (root,keys) in ps.core.pairs:
    if root notin byVid[]:
      return err((root,PartChkVidTabCoreRootMissing))
    for key in keys:
      ps.byKey.withValue(key,rvid):
        if not ps.db.getVtx(rvid[]).isValid:
          return err((rvid.vid,PartChkCoreVtxMissing))
        # Verify lookup
        if not ps.isCore key:
          return err((rvid.vid,PartChkCoreKeyLookupFailed))
        if not ps.isCore rvid[]:
          return err((rvid.vid,PartChkCoreRVidLookupFailed))
        if not ps.isCore rvid.vid:
          return err((rvid.vid,PartChkCoreVidLookupFailed))
        continue
      return err((ps[key].vid,PartChkKeyTabCoreKeyMissing))


  # All vertices for non-`core` and un-`changed` keys must not exist on database
  for (key,rvid) in ps.byKey.pairs:
    ps.core.withValue(rvid.root,keys):
      if ps.db.getVtx(rvid).isValid and
         key notin keys[] and
         key notin ps.changed:
        return err((rvid.vid,PartChkPerimeterVtxMustNotExist))
      continue
    return err((rvid.vid,PartChkKeyTabRootMissing))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
