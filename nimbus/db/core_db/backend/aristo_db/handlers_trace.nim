# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Database Backend Tracer
## =======================
##
## TODO:
##
##  While it works in the current scenario, this tracer needs a second thought
##  when it comes to transactions on different database descriptor **heads**.
##  Currently, the transaction logic is **global** (relaitive to the tracer
##  journal) but should be localised to the current **head**.
##
##  Fixing this issue will not be done until the `ctx` logic has been updated
##  for the `CoredDb` api.
##

{.push raises: [].}

import
  std/[tables, typetraits],
  eth/common,
  results,
  ../../../aristo as use_aristo,
  ../../../aristo/[aristo_desc, aristo_path],
  ../../../kvt as use_kvt,
  ../../../kvt/kvt_desc,
  ../../base,
  ../../base/base_desc,
  "."/[handlers_kvt, handlers_aristo]

const
  EnableDebugLog = CoreDbEnableApiTracking

type
  TraceKdbRecorder = object
    base: KvtBaseRef              ## Restore position
    savedApi: KvtApiRef           ## Restore data

  TraceAdbRecorder = object
    base: AristoBaseRef
    savedApi: AristoApiRef

  TracerBlobRef* = ref object
    ## `Kvt` journal entry
    blind: bool                   ## Marked `true` for `get()` logs
    old: Blob
    cur: Blob

  TracerPylRef* = ref object
    ## `Aristo` journal entry
    blind: bool                   ## Marked `true` for `fetch()` logs
    accPath: PathID               ## Account path needed for storage data
    old: PayloadRef               ## Deleted or just cached payload version
    cur: PayloadRef               ## Updated/current or just cached
    curBlob: Blob                 ## Serialised version for `cur` accounts data

  TracerBlobTabRef* =
    TableRef[Blob,TracerBlobRef]

  TracerPylTabRef* =
    TableRef[LeafTie,TracerPylRef]

  TracerLogInstRef* = ref object
    ## Logger instance
    txLevel: int
    flags: set[CoreDbCaptFlags]
    kvtJournal: TableRef[KvtDbRef,TracerBlobTabRef]
    mptJournal: TableRef[AristoDbRef,TracerPylTabRef]

  TraceRecorderRef* = ref object of RootRef
    inst: seq[TracerLogInstRef]   ## Production stack for log database
    kdb: TraceKdbRecorder         ## Contains restore information
    adb: TraceAdbRecorder         ## Contains restore information

proc push*(tr: TraceRecorderRef; flags: set[CoreDbCaptFlags]) {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when EnableDebugLog:
  import
    std/strutils,
    chronicles,
    stew/byteutils

  func toStr(key: openArray[byte]): string =
    key.toHex

  func `$`(data: Blob): string =
    data.toStr

  func `$`(lty: LeafTie): string =
    $lty.root & ":" & $lty.path

  func `$`(root: VertexID): string =
    let vid = root.uint64
    if 0 < vid:
      "$" & vid.toHex.toLowerAscii
               .strip(leading=true, trailing=false, chars={'0'})
    else:
      "$ø"

  func `$`(p: PathID): string =
    let q = desc_identifiers.`$`(p)
    if q == "(0)":
      "@ø"
    else:
      "@" & q

  func `$`(pyl: PayloadRef): string =
    case pyl.pType:
    of RawData:
      pyl.rawBlob.toStr
    of RlpData:
      pyl.rlpBlob.toStr
    of AccountData:
      "<AccountData>"

  func `$`(tpl: TracerPylRef): string =
    result = "("
    if tpl.blind:
      result &= "Touched"
    elif tpl.cur.isNil:
      result &= "Deleted"
    elif tpl.old.isNil:
      result &= "Added"
    else:
      result &= "Update"
    result &= ","

    if tpl.accPath.isValid:
      result &= $tpl.accPath
    else:
      result &= "ø"
    result &= ","

    if 0 < tpl.curBlob.len:
      result &= tpl.curBlob.toStr
    else:
      result &= $tpl.cur
    result &= ")"

  func `$`(tbl: TracerBlobRef): string =
    result = "("
    if tbl.blind:
      result &= "Touched"
    elif tbl.cur.len == 0:
      result &= "Deleted"
    elif tbl.old.len == 0:
      result &= "Added"
    else:
      result &= "Update"
    result &= "," & tbl.cur.toStr & ")"

# -------------------------

func leafTie(
    root: VertexID;
    path: openArray[byte];
      ): Result[LeafTie,(VertexID,AristoError)] =
  let tag = path.pathToTag.valueOr:
    return err((root, error))
  ok LeafTie(root: root, path: tag)

proc blobify(
    pyl: PayloadRef;
    api: AristoApiRef;
    mpt: AristoDbRef;
      ): Result[Blob,(VertexID,AristoError)] =
  var blob = EmptyBlob
  if pyl.pType == AccountData:
    blob = block:
      let rc = api.serialise(mpt, pyl)
      if rc.isOk:
        rc.value
      else:
        # TODO ? api.hashify(mpt)
        ? api.serialise(mpt, pyl)
  ok(blob)

# -------------------------------

proc kvtJournalPut(
    tr: TraceRecorderRef;
    kvt: KvtDbRef;
    key: openArray[byte];
    tbl: TracerBlobRef;
      ) =
  ## Add or update journal entry recording `kvt` modification
  var byKvt = tr.inst[^1].kvtJournal.getOrDefault kvt
  if byKvt.isNil:
    byKvt = newTable[Blob,TracerBlobRef]()
    tr.inst[^1].kvtJournal[kvt] = byKvt
  byKvt[@key] = tbl

proc kvtJournalDel(
    tr: TraceRecorderRef;
    kvt: KvtDbRef;
    key: openArray[byte];
      ) =
  ## Remove journal entry recording `kvt` modification
  var byKvt = tr.inst[^1].kvtJournal.getOrDefault kvt
  if byKvt.isNil:
    byKvt.del @key
    if byKvt.len == 0:
      tr.inst[^1].kvtJournal.del kvt

proc kvtJournalGet(
    tr: TraceRecorderRef;
    kvt: KvtDbRef;
    key: openArray[byte];
    modOnly = true;
      ): TracerBlobRef =
  ## Get journal entry recording `kvt` modification. If the argument `modOnly`
  ## is false, also blind entries are returned.
  var byKvt = tr.inst[^1].kvtJournal.getOrDefault kvt
  if not byKvt.isNil:
    let tbl = byKvt.getOrDefault @key
    if not modOnly or tbl.isNil or not tbl.blind: # or not (not isNil and blind)
      return tbl


proc mptJournalPut(
    tr: TraceRecorderRef;
    mpt: AristoDbRef;
    key: LeafTie;
    tpl: TracerPylRef;
      ) =
  ## Add or update journal entry recording `mpt` modification
  var byMpt = tr.inst[^1].mptJournal.getOrDefault mpt
  if byMpt.isNil:
    byMpt = newTable[LeafTie,TracerPylRef]()
    tr.inst[^1].mptJournal[mpt] = byMpt
  byMpt[key] = tpl

proc mptJournalDel(
    tr: TraceRecorderRef;
    mpt: AristoDbRef;
    key: LeafTie;
      ) =
  ## Remove journal entry recording `mpt` modification
  let byMpt = tr.inst[^1].mptJournal.getOrDefault mpt
  if not byMpt.isNil:
    byMpt.del key
    if byMpt.len == 0:
      tr.inst[^1].mptJournal.del mpt

proc mptJournalGet(
    tr: TraceRecorderRef;
    mpt: AristoDbRef;
    key: LeafTie;
    modOnly = true;
      ): TracerPylRef =
  ## Get journal entry recording `mpt` modification. If the argument `modOnly`
  ## is false, also blind entries are returned.
  let byMpt = tr.inst[^1].mptJournal.getOrDefault mpt
  if not byMpt.isNil:
    let pyl = byMpt.getOrDefault key
    if not modOnly or pyl.isNil or not pyl.blind: # or not (not isNil and blind)
      return pyl

proc mptJournalAcountUpdate(
    tr: TraceRecorderRef;
    mpt: AristoDbRef;
    accPath: PathID;
      ) =
  let
    lty = LeafTie(root: VertexID(1), path: accPath)
    jrn = tr.mptJournalGet(mpt, lty, modOnly=true)
  if jrn.isNil:
    # Just delete
    tr.mptJournalDel(mpt, lty)
  else:
    # Update cache
    let pyl = tr.adb.savedApi.fetchPayload(mpt, VertexID(1), @accPath).valueOr:
      raiseAssert "mptJournalAcountUpdate() failed to re-fetch($1" & "," &
        $accPath & "): " & $error
    jrn.cur.account.storageID = pyl.account.storageID
    tr.mptJournalPut(mpt, lty, jrn)


proc popDiscard(tr: TraceRecorderRef) =
  ## Pop top journal.
  doAssert 0 < tr.inst.len
  tr.inst.setLen(tr.inst.len - 1)

proc popRestore(tr: TraceRecorderRef) =
  ## Undo journals and remove/pop top entry.
  const info = "popRestore()"
  doAssert 0 < tr.inst.len

  let inst = tr.inst[^1]
  tr.inst.setLen(tr.inst.len - 1) # pop

  let mApi = tr.adb.savedApi
  for (mpt,mptTab) in inst.mptJournal.pairs:
    var deferredDelete: seq[(LeafTie, TracerPylRef)]
    for (key,tpl) in mptTab.pairs:
      if not tpl.blind:
        let (root, path, accPath) = (key.root, @(key.path), tpl.accPath)
        if tpl.old.isNil:
          if PersistPut notin inst.flags:
            # Storage tries need to be deleted first, then the accounts
            if key.root.distinctBase < LEAST_FREE_VID:
              deferredDelete.add (key,tpl)
            else:
              mApi.delete(mpt, root, path, accPath).isOkOr:
                raiseAssert info & " failed to delete(" &
                  $root & "," & $path & "," & $accPath & "): " & $error[1]
        else:
          if PersistDel notin inst.flags:
            mApi.mergePayload(mpt, root, path, tpl.old, accPath).isOkOr:
              raiseAssert info & " failed to merge(" &
                $root & "," & $path & "," & $accPath & "): " & $error
    # Delete accounts now (if any)
    for (key,tpl) in deferredDelete:
      let (root, path, accPath) = (key.root, @(key.path), tpl.accPath)
      mApi.delete(mpt, root, path, accPath).isOkOr:
        raiseAssert info & " failed to delete(" &
          $root & "," & $path & "," & $accPath & "): " & $error[1]

  let kApi = tr.kdb.savedApi
  for (kvt,kvtTab) in inst.kvtJournal.pairs:
    for (key,tbl) in kvtTab.pairs:
      if not tbl.blind:
        if tbl.old.len == 0:
          if PersistPut notin inst.flags:
            doAssert kApi.del(kvt, key).isOk
        else:
          if PersistDel notin inst.flags:
            doAssert kApi.put(kvt, key, tbl.old).isOk

proc popMerge(tr: TraceRecorderRef) =
  ## Merge top journal into layer below. The function requires at least
  ## two stack entries.
  doAssert 1 < tr.inst.len

  let inst = tr.inst[^1]
  tr.inst.setLen(tr.inst.len - 1) # pop

  for (mpt,mptTab) in inst.mptJournal.pairs:
    for (key,tpl) in mptTab.pairs:
      let jrn = tr.mptJournalGet(mpt, key)
      if not jrn.isNil:
        if jrn.old != tpl.cur:
          tpl.old = jrn.old
        else:
          tpl.blind = true
      tr.mptJournalPut(mpt, key,tpl)

  for (kvt,kvtTab) in inst.kvtJournal.pairs:
    for (key,tbl) in kvtTab.pairs:
      let jrn = tr.kvtJournalGet(kvt, key)
      if not jrn.isNil:
        if jrn.old != tbl.cur:
          tbl.old = jrn.old
        else:
          tbl.blind = true
      tr.kvtJournalPut(kvt, key,tbl)


proc pushNew(tr: TraceRecorderRef; flags: set[CoreDbCaptFlags]) =
  ## Add a new journal
  tr.inst.add TracerLogInstRef(
    kvtJournal: newTable[KvtDbRef,TracerBlobTabRef](),
    mptJournal: newTable[AristoDbRef,TracerPylTabRef](),
    flags:      flags)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc traceRecorder(
    tr: TraceRecorderRef;
    base: KvtBaseRef;
      ): TraceKdbRecorder =
  let
    api = base.api
    tracerApi = api.dup

  # Update production api
  tracerApi.get =
    proc(kvt: KvtDbRef; key: openArray[byte]): Result[Blob,KvtError] =
      when EnableDebugLog:
        const
          logTxt = "trace get"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags

      # Use journal entry if available
      let jrn = tr.kvtJournalGet(kvt, key, modOnly=false)
      if not jrn.isNil:
        when EnableDebugLog:
          debug logTxt, level, flags, key=key.toStr, log="get()", data=($jrn)
        if jrn.cur.len == 0:
          return err(use_kvt.GetNotFound)
        else:
          return ok jrn.cur

      let
        # Find entry on DB
        data = api.get(kvt, key).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, key=key.toStr, error
          return err(error) # No way

        # Journal entry
        tbl = TracerBlobRef(blind: true, cur: data)

      # Update journal
      tr.kvtJournalPut(kvt, key, tbl)
      when EnableDebugLog:
        debug logTxt, level, flags, key=key.toStr, data=($tbl)

      ok(data)

  tracerApi.del =
    proc(kvt: KvtDbRef; key: openArray[byte]): Result[void,KvtError] =
      when EnableDebugLog:
        const
          logTxt = "trace del"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags
      let
        # Find entry on DB
        data = api.get(kvt, key).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, key=key.toStr, error
          if error != use_kvt.GetNotFound:
            return err(error)
          return ok()

      # Delete from DB
      api.del(kvt, key).isOkOr:
        when EnableDebugLog:
          debug logTxt, level, flags, key=key.toStr, error
        return err(error)

      # Update journal
      let jrn = tr.kvtJournalGet(kvt, key)
      if jrn.isNil:
        let tbl = TracerBlobRef(old: data)
        tr.kvtJournalPut(kvt, key, tbl)
        when EnableDebugLog:
          debug logTxt, level, flags, key=key.toStr, log="put()", data=($tbl)

      elif jrn.old.len == 0:
        # Was just added earlier
       tr.kvtJournalDel(kvt, key) # Undo earlier stuff
       when EnableDebugLog:
         debug logTxt, level, flags, key=key.toStr, log="del()"

      else:
        # Was modified earlier
        let tbl = TracerBlobRef(old: jrn.old)
        tr.kvtJournalPut(kvt, key, tbl)
        when EnableDebugLog:
          debug logTxt, level, flags, key=key.toStr, log="put()", data=($tbl)

      ok()

  tracerApi.put =
    proc(kvt: KvtDbRef; key, data: openArray[byte]): Result[void,KvtError] =
      when EnableDebugLog:
        const
          logTxt = "trace put"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags
      let
        # Create journal entry
        tbl = TracerBlobRef(cur: @data)

      # Update journal entry so that previous state is saved
      let jrn = tr.kvtJournalGet(kvt, key)
      if jrn.isNil:
        # Find current entry on the DB
        let rc = api.get(kvt, key)
        if rc.isOk:
          tbl.old = rc.value
        elif rc.error != use_kvt.GetNotFound:
          when EnableDebugLog:
            debug logTxt, level, flags, key=key.toStr, error=rc.error
          return err(rc.error)
      elif 0 < jrn.old.len:
        tbl.old = jrn.old

      # Store on DB
      api.put(kvt, key, data).isOkOr:
        when EnableDebugLog:
          debug logTxt, level, flags, key=key.toStr, data=data.toStr
        return err(error)

      tr.kvtJournalPut(kvt, key, tbl)
      when EnableDebugLog:
        debug logTxt, level, flags, key=key.toStr, data=($tbl)

      ok()

  # It is enough to catch transactions on the `Kvt` tracer only
  tracerApi.txBegin =
    proc(kvt: KvtDbRef): Result[KvtTxRef,KvtError] =
      when EnableDebugLog:
        const
          logTxt = "trace txBegin"
        let
          level = tr.inst.len - 1
          txLevel = tr.inst[^1].txLevel
      let
        flags = tr.inst[^1].flags
        tx = api.txBegin(kvt).valueOr:
          when EnableDebugLog:
            debug logTxt, level, txLevel, flags, error
          return err(error)

      tr.push flags
      tr.inst[^1].txLevel = api.level kvt
      doAssert 0 < tr.inst[^1].txLevel
      when EnableDebugLog:
        debug logTxt, level=(level+1), txLevel= tr.inst[^1].txLevel, flags

      ok tx

  tracerApi.commit =
    proc(tx: KvtTxRef): Result[void,KvtError] =
      when EnableDebugLog:
        const
          logTxt = "trace commit"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags
          txLevel = tr.inst[^1].txLevel
        debug logTxt, level, txLevel, flags

      # Make sure that the system is properly nested
      doAssert tr.inst[^1].txLevel == api.level api.toKvtDbRef(tx)
      tr.popMerge()

      api.commit(tx).isOkOr:
        when EnableDebugLog:
          debug logTxt, level, txLevel, flags, error
        return err(error)

      ok()

  tracerApi.rollback =
    proc(tx: KvtTxRef): Result[void,KvtError] =
      when EnableDebugLog:
        const
          logTxt = "trace rollback"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags
          txLevel = tr.inst[^1].txLevel
        debug logTxt, level, txLevel, flags

      # Make sure that the system is properly nested
      doAssert tr.inst[^1].txLevel == api.level api.toKvtDbRef(tx)
      tr.popDiscard()

      api.rollback(tx).isOkOr:
        when EnableDebugLog:
          debug logTxt, level, txLevel, flags, error
        return err(error)

      ok()

  result = TraceKdbRecorder(
    base:     base,
    savedApi: api)
  base.api = tracerApi

  assert result.savedApi != base.api
  assert result.savedApi.del != base.api.del
  assert result.savedApi.hasKey == base.api.hasKey


proc traceRecorder(
    tr: TraceRecorderRef;
    base: AristoBaseRef;
      ): TraceAdbRecorder =
  let
    api = base.api
    tracerApi = api.dup

  tracerApi.fetchPayload =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
           ): Result[PayloadRef,(VertexID,AristoError)] =
      when EnableDebugLog:
        const
          logTxt = "trace fetchPayload"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags
      let
        key = leafTie(root, path).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, root, path=path.toStr, error=error[1]
          return err(error)

      let jrn = tr.mptJournalGet(mpt, key, modOnly=false)
      if not jrn.isNil:
        when EnableDebugLog:
          debug logTxt, level, flags, key, log="get()", data=($jrn)
        if jrn.cur.isNil:
          return err((VertexID(0),FetchPathNotFound))
        else:
          return ok jrn.cur

      let
        # Find on DB
        pyl = api.fetchPayload(mpt, root, path).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, key, error=error[1]
          return err(error)

        # Serialise (if needed)
        blob = pyl.blobify(api, mpt).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, key, error=error[1]
          return err(error)

        # Journal entry
        tPyl = TracerPylRef(blind: true, cur: pyl, curBlob: blob)

      # Update journal
      tr.mptJournalPut(mpt, key, tPyl)
      when EnableDebugLog:
        debug logTxt, level, flags, key, log="put()", data=($tPyl)

      ok pyl

  tracerApi.delete =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
         accPath: PathID;
           ): Result[bool,(VertexID,AristoError)] =
      when EnableDebugLog:
        const
          logTxt = "trace delete"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags
      let
        key = leafTie(root, path).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, root, path=path.toStr, error=error[1]
          return err(error)

        # Find entry on the DB
        pyl = api.fetchPayload(mpt, root, path).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, key, error=error[1]
          if error[1] == FetchPathNotFound:
            return err((error[0], DelPathNotFound))
          return err(error)

        # Delete from DB
        deleted = api.delete(mpt, root, path, accPath).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, key, error
          return err(error)

      # Update journal
      let jrn = tr.mptJournalGet(mpt, key)
      if jrn.isNil:
        let tpl = TracerPylRef(old: pyl, accPath: accPath)
        tr.mptJournalPut(mpt, key, tpl)
        when EnableDebugLog:
          debug logTxt, level, flags, key, log="put()", data=($tpl)

      elif jrn.old.isNil:
        # Was just added earlier
       tr.mptJournalDel(mpt, key) # Undo earlier stuff
       when EnableDebugLog:
         debug logTxt, level, flags, key, log="del()"

      else:
        # Was modified earlier, keep the old value
        let tpl = TracerPylRef(old: jrn.old, accPath: jrn.accPath)
        tr.mptJournalPut(mpt, key, tpl)
        when EnableDebugLog:
          debug logTxt, level, flags, key, log="put()", data=($tpl)

      if LEAST_FREE_VID <= root.distinctBase:
        tr.mptJournalAcountUpdate(mpt, accPath)

      ok deleted

  tracerApi.delTree =
    proc(mpt: AristoDbRef;
         root: VertexID;
         accPath: PathID;
           ): Result[void,(VertexID,AristoError)] =
      when EnableDebugLog:
        const
          logTxt = "trace delTree"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags

      # TODO: collect all paths on this tree
      var deletedRows: seq[(LeafTie,PayloadRef)]

      # Delete from DB
      api.delTree(mpt, root, accPath).isOkOr:
        when EnableDebugLog:
          debug logTxt, level, flags, error
        return err(error)

      # Update journal
      for (key,pyl) in deletedRows:
        let jrn = tr.mptJournalGet(mpt, key)
        if jrn.isNil:
          let tpl = TracerPylRef(old: pyl, accPath: accPath)
          tr.mptJournalPut(mpt, key, tpl)
          when EnableDebugLog:
            debug logTxt, level, flags, key, log="put()", data=($tpl)
        elif jrn.old.isNil:
          # Was just added earlier
          tr.mptJournalDel(mpt, key) # Undo earlier stuff
          when EnableDebugLog:
            debug logTxt, level, flags, key, log="del()"
        else:
          # Was modified earlier, keep the old value
          let tpl = TracerPylRef(old: jrn.old, accPath: jrn.accPath)
          tr.mptJournalPut(mpt, key, tpl)
          when EnableDebugLog:
            debug logTxt, level, flags, key, log="put()", data=($tpl)

      if LEAST_FREE_VID <= root.distinctBase:
        tr.mptJournalAcountUpdate(mpt, accPath)

      ok()

  tracerApi.merge =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
         data: openArray[byte];
         accPath: PathID;
           ): Result[bool,AristoError] =
      when EnableDebugLog:
        const
          logTxt = "trace merge"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags
      let
        key = leafTie(root, path).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, root, path=path.toStr, error=error[1]
          return err(error[1])

        # Create journal entry, `pType` same as generated by `merge()`
        tpl = TracerPylRef(
          accPath: accPath,
          cur:     PayloadRef(pType: RawData, rawBlob: @data))

      # Update journal
      let jrn = tr.mptJournalGet(mpt, key)
      if jrn.isNil:
        # Find current entry on the DB
        let rc = api.fetchPayload(mpt, root, path)
        if rc.isOk:
          tpl.old = rc.value
        elif rc.error[1] != FetchPathNotFound:
          when EnableDebugLog:
            debug logTxt, level, flags, key, error=rc.error[1]
          return err(rc.error[1])
      elif not jrn.old.isNil:
        tpl.old = jrn.old
        tpl.accPath = jrn.accPath

      # Merge on DB
      let merged = api.merge(mpt, root, path, data, accPath).valueOr:
        when EnableDebugLog:
          debug logTxt, level, flags, key, accPath, error
        return err(error)

      if LEAST_FREE_VID <= root.distinctBase:
        tr.mptJournalAcountUpdate(mpt, accPath)

      tr.mptJournalPut(mpt, key, tpl)
      when EnableDebugLog:
        debug logTxt, level, flags, key, accPath, log="put()", data=($tpl)

      ok merged

  tracerApi.mergePayload =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
         pyl: PayloadRef;
         accPath = VOID_PATH_ID;
           ): Result[bool,AristoError] =
      when EnableDebugLog:
        const
          logTxt = "trace mergePayload"
        let
          level = tr.inst.len - 1
          flags = tr.inst[^1].flags
      let
        key = leafTie(root, path).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, root, path=path.toStr, error=error[1]
          return err(error[1])

        # Create serialised payload
        blob = pyl.blobify(api, mpt).valueOr:
          when EnableDebugLog:
            debug logTxt, level, flags, key, error=error[1]
          return err(error[1])

        # Create journal entry
        tpl = TracerPylRef(
          accPath: accPath,
          cur:     pyl,
          curBlob: blob)

      # Update journal
      let jrn = tr.mptJournalGet(mpt, key)
      if jrn.isNil:
        # Find current entry on the DB
        let rc = api.fetchPayload(mpt, root, path)
        if rc.isOk:
          tpl.old = rc.value
        elif rc.error[1] != FetchPathNotFound:
          when EnableDebugLog:
            debug logTxt, level, flags, key, error=rc.error[1]
          return err(rc.error[1])
      elif not jrn.old.isNil:
        tpl.old = jrn.old
        tpl.accPath = jrn.accPath

      # Merge on DB
      let merged = api.mergePayload(mpt, root, path, pyl, accPath).valueOr:
        when EnableDebugLog:
          debug logTxt, level, flags, key, accPath, error
        return err(error)

      if LEAST_FREE_VID <= root.distinctBase:
        tr.mptJournalAcountUpdate(mpt, accPath)

      tr.mptJournalPut(mpt, key, tpl)
      when EnableDebugLog:
        debug logTxt, level, flags, key, accPath, log="put()", data=($tpl)

      ok merged

  result = TraceAdbRecorder(
    base:     base,
    savedApi: api)
  base.api = tracerApi

  assert result.savedApi != base.api
  assert result.savedApi.delete != base.api.delete
  assert result.savedApi.commit == base.api.commit

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc topInst*(tr: TraceRecorderRef): TracerLogInstRef =
  ## Get top level KVT logger
  doAssert 0 < tr.inst.len
  tr.inst[^1]

func kLog*(inst: TracerLogInstRef): TableRef[Blob,Blob] =
  ## Export `Kvt` journal
  result = newTable[Blob,Blob]()
  for (_,kvtTab) in inst.kvtJournal.pairs:
    for (key,tbl) in kvtTab.pairs:
      if tbl.cur.len != 0:
        result[key] = tbl.cur

func mLog*(inst: TracerLogInstRef): TableRef[LeafTie,PayloadRef] =
  ## Export `mpt` journal
  result = newTable[LeafTie,PayloadRef]()
  for (_,mptTab) in inst.mptJournal.pairs:
    for (key,tpl) in mptTab.pairs:
      if not tpl.cur.isNil:
        result[key] = tpl.cur

func flags*(inst: TracerLogInstRef): set[CoreDbCaptFlags] =
  ## Getter
  inst.flags

proc pop*(tr: TraceRecorderRef): bool =
  ## Reduce logger stack, returns `true` on success. There will always be
  ## at least one logger left on stack.
  if 1 < tr.inst.len: # Always leave one instance on stack
    tr.popRestore()
    return true

proc push*(
    tr: TraceRecorderRef;
    flags: set[CoreDbCaptFlags];
      ) =
  ## Push overlay logger instance
  doAssert 0 < tr.inst.len
  tr.pushNew flags

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc init*(
    tr: TraceRecorderRef;         # Recorder desc to initialise
    kBase: KvtBaseRef;            # `Kvt` base descriptor
    aBase: AristoBaseRef;         # `Aristo` base descriptor
    flags: set[CoreDbCaptFlags];
      ) =
  ## Constructor, create initial/base tracer descriptor
  tr.inst.setLen(0)
  tr.pushNew flags
  tr.kdb = tr.traceRecorder kBase
  tr.adb = tr.traceRecorder aBase

proc restore*(tr: TraceRecorderRef) =
  ## Restore production API.
  while 0 < tr.inst.len:
    tr.popRestore()
  tr.kdb.base.api = tr.kdb.savedApi
  tr.adb.base.api = tr.adb.savedApi

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
