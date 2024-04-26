# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[algorithm, sequtils, sets, tables],
  eth/common,
  results,
  ../aristo_filter/filter_scheduler,
  ../aristo_walk/persistent,
  ".."/[aristo_desc, aristo_blobify]

const
  ExtraDebugMessages = false

type
  JrnRec = tuple
    src: Hash256
    trg: Hash256
    size: int

when ExtraDebugMessages:
  import
    ../aristo_debug

# ------------------------------------------------------------------------------
# Private functions and helpers
# ------------------------------------------------------------------------------

template noValueError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert info & ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""

when ExtraDebugMessages:
  proc pp(t: var Table[QueueID,JrnRec]): string =
    result = "{"
    for qid in t.keys.toSeq.sorted:
      t.withValue(qid,w):
        result &= qid.pp & "#" & $w[].size & ","
    if result[^1] == '{':
      result &= "}"
    else:
      result[^1] = '}'

  proc pp(t: seq[QueueID]): string =
    result = "{"
    var list = t
    for n in 2 ..< list.len:
      if list[n-1] == list[n] - 1 and
         (list[n-2] == QueueID(0) or list[n-2] == list[n] - 2):
        list[n-1] = QueueID(0)
    for w in list:
      if w != QueueID(0):
        result &= w.pp & ","
      elif result[^1] == ',':
        result[^1] = '.'
        result &= "."
    if result[^1] == '{':
      result &= "}"
    else:
      result[^1] = '}'

  proc pp(t: HashSet[QueueID]): string =
    result = "{"
    var list = t.toSeq.sorted
    for n in 2 ..< list.len:
      if list[n-1] == list[n] - 1 and
         (list[n-2] == QueueID(0) or list[n-2] == list[n] - 2):
        list[n-1] = QueueID(0)
    for w in list:
      if w != QueueID(0):
        result &= w.pp & ","
      elif result[^1] == ',':
        result[^1] = '.'
        result &= "."
    if result[^1] == '{':
      result &= "}"
    else:
      result[^1] = '}'

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkJournal*[T: RdbBackendRef|MemBackendRef](
    _: type T;
    db: AristoDbRef;
      ): Result[void,(QueueID,AristoError)] =
  let jrn = db.backend.journal
  if jrn.isNil: return ok()

  var
    nToQid: seq[QueueID]             # qids sorted by history/age
    cached: HashSet[QueueID]         # `nToQid[]` as set
    saved: Table[QueueID,JrnRec]
    error: (QueueID,AristoError)

  when ExtraDebugMessages:
    var
      sizeTally = 0
      maxBlock = 0

    proc moan(n = -1, s = "", listOk = true) =
      var txt = ""
      if 0 <= n:
        txt &= " (" & $n & ")"
      if error[1] != AristoError(0):
        txt &= " oops"
      txt &=
        " jLen=" & $jrn.len &
        " tally=" & $sizeTally &
        " maxBlock=" & $maxBlock &
        ""
      if 0 < s.len:
        txt &= " " & s
      if error[1] != AristoError(0):
        txt &=
          " errQid=" &  error[0].pp &
          " error=" &  $error[1] &
          ""
      if listOk:
        txt &=
          "\n    cached=" &  cached.pp &
          "\n    saved=" & saved.pp &
          ""
      debugEcho "*** checkJournal", txt
  else:
    template moan(n = -1, s = "", listOk = true) =
      discard

  # Collect cached handles
  for n in 0 ..< jrn.len:
    let qid = jrn[n]
    # Must be no overlap
    if qid in cached:
      error = (qid,CheckJrnCachedQidOverlap)
      moan(2)
      return err(error)
    cached.incl qid
    nToQid.add qid

  # Collect saved data
  for (qid,fil) in db.backend.T.walkFilBe():
    var jrnRec: JrnRec
    jrnRec.src = fil.src
    jrnRec.trg = fil.trg

    when ExtraDebugMessages:
      let rc = fil.blobify
      if rc.isErr:
        moan(5)
        return err((qid,rc.error))
      jrnRec.size = rc.value.len
      if maxBlock < jrnRec.size:
        maxBlock = jrnRec.size
      sizeTally += jrnRec.size

    saved[qid] = jrnRec

  # Compare cached against saved data
  let
    savedQids = saved.keys.toSeq.toHashSet
    unsavedQids = cached - savedQids
    staleQids = savedQids - cached

  if 0 < unsavedQids.len:
    error = (unsavedQids.toSeq.sorted[0],CheckJrnSavedQidMissing)
    moan(6)
    return err(error)

  if 0 < staleQids.len:
    error = (staleQids.toSeq.sorted[0], CheckJrnSavedQidStale)
    moan(7)
    return err(error)

  # Compare whether journal records link together
  if 1 < nToQid.len:
    noValueError("linked journal records"):
      var prvRec = saved[nToQid[0]]
      for n in 1 ..< nToQid.len:
        let thisRec = saved[nToQid[n]]
        if prvRec.trg != thisRec.src:
          error = (nToQid[n],CheckJrnLinkingGap)
          moan(8, "qidInx=" & $n)
          return err(error)
        prvRec = thisRec

  moan(9, listOk=false)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
