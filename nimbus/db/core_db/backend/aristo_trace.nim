# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
## Database Backend Tracer
## =======================
##

{.push raises: [].}

import
  std/[sequtils, tables, typetraits],
  eth/common,
  results,
  ../../aristo as use_aristo,
  ../../aristo/aristo_desc,
  ../../kvt as use_kvt,
  ../../kvt/kvt_desc,
  ../base/[base_config, base_desc]

const
  LogJournalMax = 1_000_000
    ## Maximal size of a journal (organised as LRU)

type
  TracePfx = enum
    TrpOops = 0
    TrpKvt
    TrpAccounts
    TrpGeneric
    TrpStorage

  TraceRequest* = enum
    TrqOops = 0
    TrqFind
    TrqAdd
    TrqModify
    TrqDelete

  TraceDataType* = enum
    TdtOops = 0
    TdtBlob                       ## Kvt and Aristo
    TdtError                      ## Kvt and Aristo
    TdtVoid                       ## Kvt and Aristo
    TdtAccount                    ## Aristo only
    TdtBigNum                     ## Aristo only
    TdtHash                       ## Aristo only

  TraceDataItemRef* = ref object
    ## Log journal entry
    pfx*: TracePfx                ## DB storage prefix
    info*: int                    ## `KvtApiProfNames` or `AristoApiProfNames`
    req*: TraceRequest            ## Logged action request
    case kind*: TraceDataType
    of TdtBlob:
      blob*: Blob
    of TdtError:
      error*: int                 ## `KvtError` or `AristoError`
    of TdtAccount:
      account*: AristoAccount
    of TdtBigNum:
      bigNum*: UInt256
    of TdtHash:
      hash*: Hash256
    of TdtVoid, TdtOops:
      discard

  TraceLogInstRef* = ref object
    ## Logger instance
    base: TraceRecorderRef
    level: int
    truncated: bool
    journal: KeyedQueue[Blob,TraceDataItemRef]

  TraceRecorderRef* = ref object of RootRef
    log: seq[TraceLogInstRef]     ## Production stack for log database
    db: CoreDbRef
    kvtSave: KvtApiRef             ## Restore `KVT` data
    ariSave: AristoApiRef          ## Restore `Aristo` data

doAssert LEAST_FREE_VID <= 256 # needed for journal key byte prefix

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when CoreDbNoisyCaptJournal:
  import
    std/strutils,
    chronicles,
    stew/byteutils

  func squeezeHex(s: string; ignLen = false): string =
    result = if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. ^1]
    if not ignLen:
      let n = (s.len + 1) div 2
      result &= "[" & (if 0 < n: "#" & $n else: "") & "]"

  func stripZeros(a: string; toExp = false): string =
    if 0 < a.len:
      result = a.toLowerAscii.strip(leading=true, trailing=false, chars={'0'})
      if result.len == 0:
        result = "0"
      elif result[^1] == '0' and toExp:
        var n = 0
        while result[^1] == '0':
          let w = result.len
          result.setLen(w-1)
          n.inc
        if n == 1:
          result &= "0"
        elif n == 2:
          result &= "00"
        elif 2 < n:
          result &= "↑" & $n

  func `$$`(w: openArray[byte]): string =
    w.toHex.squeezeHex

  func `$`(w: Blob): string =
    w.toHex.squeezeHex

  func `$`(w: UInt256): string =
    "#" & w.toHex.stripZeros.squeezeHex

  func `$`(w: Hash256): string =
    "£" & w.data.toHex.squeezeHex

  func `$`(w: VertexID): string =
    if 0 < w.uint64: "$" & w.uint64.toHex.stripZeros else: "$ø"

  func `$`(w: AristoAccount): string =
    "(" & $w.nonce & "," & $w.balance & "," & $w.codeHash & ")"

  func `$`(ti: TraceDataItemRef): string =
    result = "(" &
      (if ti.pfx == TrpKvt: $KvtApiProfNames(ti.info)
       elif ti.pfx == TrpOops: "<oops>"
       else: $AristoApiProfNames(ti.info))

    result &= "," & (
      case ti.req:
      of TrqOops: "<oops>"
      of TrqFind: ""
      of TrqModify: "="
      of TrqDelete: "-"
      of TrqAdd: "+")

    result &= (
      case ti.kind:
      of TdtOops: "<oops>"
      of TdtBlob: $ti.blob
      of TdtBigNum: $ti.bigNum
      of TdtHash: $ti.hash
      of TdtVoid: "ø"
      of TdtError: (if ti.pfx == TrpKvt: $KvtError(ti.error)
                    elif ti.pfx == TrpOops: "<oops>"
                    else: $AristoError(ti.error))
      of TdtAccount: $ti.account)

    result &= ")"

  func toStr(pfx: TracePfx, key: openArray[byte]): string =
    case pfx:
    of TrpOops:
      "<oops>"
    of TrpKvt:
      $$(key.toOpenArray(0, key.len - 1))
    of TrpAccounts:
      "1:" & $$(key.toOpenArray(0, key.len - 1))
    of TrpGeneric:
      $key[0] & ":" & $$(key.toOpenArray(1, key.len - 1))
    of TrpStorage:
      "1:" & $$(key.toOpenArray(0, min(31, key.len - 1))) & ":" &
        (if 32 < key.len: $$(key.toOpenArray(32, key.len - 1)) else: "")

  func `$`(key: openArray[byte]; ti: TraceDataItemRef): string =
    "(" &
      TracePfx(key[0]).toStr(key.toOpenArray(1, key.len - 1)) & "," &
      $ti & ")"

# -------------------------------

template logTxt(info: static[string]): static[string] =
  "trace " & info

func topLevel(tr: TraceRecorderRef): int =
  tr.log.len - 1

# --------------------

proc jLogger(
    tr: TraceRecorderRef;
    key: openArray[byte];
    ti: TraceDataItemRef;
      ) =
  ## Add or update journal entry. The `tr.pfx` argument indicates the key type:
  ##
  ## * `TrpKvt`: followed by KVT key
  ## * `TrpAccounts`: followed by <account-path>
  ## * `TrpGeneric`: followed by <root-ID> + <path>
  ## * `TrpStorage`: followed by <account-path> + <storage-path>
  ##
  doAssert ti.pfx != TrpOops
  let
    pfx = @[ti.pfx.byte]
    lRec = tr.log[^1].journal.lruFetch(pfx & @key).valueOr:
      if LogJournalMax <= tr.log[^1].journal.len:
        tr.log[^1].truncated = true
      discard tr.log[^1].journal.lruAppend(pfx & @key, ti, LogJournalMax)
      return
  if ti.req != TrqFind:
    lRec[] = ti[]

proc jLogger(
    tr: TraceRecorderRef;
    accPath: Hash256;
    ti: TraceDataItemRef;
      ) =
  tr.jLogger(accPath.data.toSeq, ti)

proc jLogger(
    tr: TraceRecorderRef;
    ti: TraceDataItemRef;
      ) =
  tr.jLogger(EmptyBlob, ti)

proc jLogger(
    tr: TraceRecorderRef;
    root: VertexID;
    path: openArray[byte];
    ti: TraceDataItemRef;
      ) =
  tr.jLogger(@[root.byte] & @path, ti)

proc jLogger(
    tr: TraceRecorderRef;
    root: VertexID;
    ti: TraceDataItemRef;
      ) =
  tr.jLogger(@[root.byte], ti)

proc jLogger(
    tr: TraceRecorderRef;
    accPath: Hash256;
    stoPath: Hash256;
    ti: TraceDataItemRef;
      ) =
  tr.jLogger(accPath.data.toSeq & stoPath.data.toSeq, ti)

# --------------------

func to(w: AristoApiProfNames; T: type TracePfx): T =
  case w:
  of AristoApiProfFetchAccountRecordFn,
     AristoApiProfFetchAccountStateFn,
     AristoApiProfDeleteAccountRecordFn,
     AristoApiProfMergeAccountRecordFn:
    return TrpAccounts
  of AristoApiProfFetchGenericDataFn,
     AristoApiProfFetchGenericStateFn,
     AristoApiProfDeleteGenericDataFn,
     AristoApiProfDeleteGenericTreeFn,
     AristoApiProfMergeGenericDataFn:
    return TrpGeneric
  of AristoApiProfFetchStorageDataFn,
     AristoApiProfFetchStorageStateFn,
     AristoApiProfDeleteStorageDataFn,
     AristoApiProfDeleteStorageTreeFn,
     AristoApiProfMergeStorageDataFn:
    return TrpStorage
  else:
    discard
  raiseAssert "Unsupported AristoApiProfNames: " & $w

func to(w: KvtApiProfNames; T: type TracePfx): T =
  TrpKvt

# --------------------

func logRecord(
    info: KvtApiProfNames | AristoApiProfNames;
    req: TraceRequest;
    data: openArray[byte];
      ): TraceDataItemRef =
  TraceDataItemRef(
    pfx:  info.to(TracePfx),
    info: info.ord,
    req:  req,
    kind: TdtBlob,
    blob: @data)

func logRecord(
    info: KvtApiProfNames | AristoApiProfNames;
    req: TraceRequest;
    error: KvtError | AristoError;
      ): TraceDataItemRef =
  TraceDataItemRef(
    pfx:   info.to(TracePfx),
    info:  info.ord,
    req:   req,
    kind:  TdtError,
    error: error.ord)

func logRecord(
    info: KvtApiProfNames | AristoApiProfNames;
    req: TraceRequest;
      ): TraceDataItemRef =
  TraceDataItemRef(
    pfx:  info.to(TracePfx),
    info: info.ord,
    req:  req,
    kind: TdtVoid)

# --------------------

func logRecord(
    info: AristoApiProfNames;
    req: TraceRequest;
    accRec: AristoAccount;
      ): TraceDataItemRef =
  TraceDataItemRef(
    pfx:     info.to(TracePfx),
    info:    info.ord,
    req:     req,
    kind:    TdtAccount,
    account: accRec)

func logRecord(
    info: AristoApiProfNames;
    req: TraceRequest;
    state: Hash256;
      ): TraceDataItemRef =
  TraceDataItemRef(
    pfx:  info.to(TracePfx),
    info: info.ord,
    req:  req,
    kind: TdtHash,
    hash: state)

func logRecord(
    info: AristoApiProfNames;
    req: TraceRequest;
    sto: Uint256;
      ): TraceDataItemRef =
  TraceDataItemRef(
    pfx:    info.to(TracePfx),
    info:   info.ord,
    req:    req,
    kind:   TdtBigNum,
    bigNum: sto)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc kvtTraceRecorder(tr: TraceRecorderRef) =
  let
    api = tr.db.kvtApi
    tracerApi = api.dup

  # Set up new production api `tracerApi` and save the old one
  tr.kvtSave = api
  tr.db.kvtApi = tracerApi

  # Update production api
  tracerApi.get =
    proc(kvt: KvtDbRef; key: openArray[byte]): Result[Blob,KvtError] =
      const info = KvtApiProfGetFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      let data = api.get(kvt, key).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, key=($$key), error
        tr.jLogger(key, logRecord(info, TrqFind, error))
        return err(error) # No way

      tr.jLogger(key, logRecord(info, TrqFind, data))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, key=($$key), data=($$data)
      ok(data)

  tracerApi.del =
    proc(kvt: KvtDbRef; key: openArray[byte]): Result[void,KvtError] =
      const info = KvtApiProfDelFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB (for comprehensive log record)
      let tiRec = block:
        let rc = api.get(kvt, key)
        if rc.isOk:
          logRecord(info, TrqDelete, rc.value)
        elif rc.error == GetNotFound:
          logRecord(info, TrqDelete)
        else:
          when CoreDbNoisyCaptJournal:
            debug logTxt $info, level, key=($$key), error=rc.error
          tr.jLogger(key, logRecord(info, TrqDelete, rc.error))
          return err(rc.error)

      # Delete from DB
      api.del(kvt, key).isOkOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, key=($$key), error
        tr.jLogger(key, logRecord(info, TrqDelete, error))
        return err(error)

      # Log on journal
      tr.jLogger(key, tiRec)

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, key=($$key)
      ok()

  tracerApi.put =
    proc(kvt: KvtDbRef; key, data: openArray[byte]): Result[void,KvtError] =
      const info = KvtApiProfPutFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB
      let
        hasKey = api.hasKeyRc(kvt, key).valueOr:
          when CoreDbNoisyCaptJournal:
            debug logTxt $info, level, key=($$key), error
          tr.jLogger(key, logRecord(info, TrqAdd, error))
          return err(error)
        mode = if hasKey: TrqModify else: TrqAdd

      # Store on DB
      api.put(kvt, key, data).isOkOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, key=($$key), data=($$data)
        tr.jLogger(key, logRecord(info, mode, error))
        return err(error)

      tr.jLogger(key, logRecord(info, mode, data))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, key=($$key), data=($$data)
      ok()

  assert tr.kvtSave != tr.db.kvtApi
  assert tr.kvtSave.del != tr.db.kvtApi.del
  assert tr.kvtSave.hasKeyRc == tr.db.kvtApi.hasKeyRc


proc ariTraceRecorder(tr: TraceRecorderRef) =
  let
    api = tr.db.ariApi
    tracerApi = api.dup

  # Set up new production api `tracerApi` and save the old one
  tr.ariSave = api
  tr.db.ariApi = tracerApi

  tracerApi.fetchAccountRecord =
    proc(mpt: AristoDbRef;
         accPath: Hash256;
        ): Result[AristoAccount,AristoError] =
      const info = AristoApiProfFetchAccountRecordFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB
      let accRec = api.fetchAccountRecord(mpt, accPath).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, accPath, error
        tr.jLogger(accPath, logRecord(info, TrqFind, error))
        return err(error)

      tr.jLogger(accPath, logRecord(info, TrqFind, accRec))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, accPath, accRec
      ok accRec

  tracerApi.fetchAccountState =
    proc(mpt: AristoDbRef;
         updateOk: bool;
        ): Result[Hash256,AristoError] =
      const info = AristoApiProfFetchAccountStateFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB
      let state = api.fetchAccountState(mpt, updateOk).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, updateOk, error
        tr.jLogger logRecord(info, TrqFind, error)
        return err(error)

      tr.jLogger logRecord(info, TrqFind, state)

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, updateOk, state
      ok state

  tracerApi.fetchGenericData =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
        ): Result[Blob,AristoError] =
      const info = AristoApiProfFetchGenericDataFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB
      let data = api.fetchGenericData(mpt, root, path).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, root, path=($$path), error
        tr.jLogger(root, path, logRecord(info, TrqFind, error))
        return err(error)

      tr.jLogger(root, path, logRecord(info, TrqFind, data))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, root, path=($$path), data
      ok data

  tracerApi.fetchGenericState =
    proc(mpt: AristoDbRef;
         root: VertexID;
         updateOk: bool;
        ): Result[Hash256,AristoError] =
      const info = AristoApiProfFetchGenericStateFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB
      let state = api.fetchAccountState(mpt, updateOk).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, root, updateOk, error
        tr.jLogger(root, logRecord(info, TrqFind, error))
        return err(error)

      tr.jLogger(root, logRecord(info, TrqFind, state))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, root, updateOk, state
      ok state

  tracerApi.fetchStorageData =
    proc(mpt: AristoDbRef;
         accPath: Hash256;
         stoPath: Hash256;
        ): Result[Uint256,AristoError] =
      const info = AristoApiProfFetchStorageDataFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB
      let stoData = api.fetchStorageData(mpt, accPath, stoPath).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, accPath, stoPath, error
        tr.jLogger(accPath, stoPath, logRecord(info, TrqFind, error))
        return err(error)

      tr.jLogger(accPath, stoPath, logRecord(info, TrqFind, stoData))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, accPath, stoPath, stoData
      ok stoData

  tracerApi.fetchStorageState =
    proc(mpt: AristoDbRef;
         accPath: Hash256;
         updateOk: bool;
        ): Result[Hash256,AristoError] =
      const info = AristoApiProfFetchStorageStateFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB
      let state = api.fetchStorageState(mpt, accPath, updateOk).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, accPath, updateOk, error
        tr.jLogger(accPath, logRecord(info, TrqFind, error))
        return err(error)

      tr.jLogger(accPath, logRecord(info, TrqFind, state))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, accPath, updateOk, state
      ok state

  tracerApi.deleteAccountRecord =
    proc(mpt: AristoDbRef;
         accPath: Hash256;
        ): Result[void,AristoError] =
      const info = AristoApiProfDeleteAccountRecordFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB (for comprehensive log record)
      let tiRec = block:
        let rc = api.fetchAccountRecord(mpt, accPath)
        if rc.isOk:
          logRecord(info, TrqDelete, rc.value)
        elif rc.error == FetchPathNotFound:
          logRecord(info, TrqDelete)
        else:
          when CoreDbNoisyCaptJournal:
            debug logTxt $info, level, accPath, error=rc.error
          tr.jLogger(accPath, logRecord(info, TrqDelete, rc.error))
          return err(rc.error)

      # Delete from DB
      api.deleteAccountRecord(mpt, accPath).isOkOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, accPath, error
        tr.jLogger(accPath, logRecord(info, TrqDelete, error))
        return err(error)

      # Log on journal
      tr.jLogger(accPath, tiRec)

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, accPath
      ok()

  tracerApi.deleteGenericData =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
        ): Result[bool,AristoError] =
      const info = AristoApiProfDeleteGenericDataFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB (for comprehensive log record)
      let tiRec = block:
        let rc = api.fetchGenericData(mpt, root, path)
        if rc.isOk:
          logRecord(info, TrqDelete, rc.value)
        elif rc.error == FetchPathNotFound:
          logRecord(info, TrqDelete)
        else:
          when CoreDbNoisyCaptJournal:
            debug logTxt $info, level, root, path=($$path), error=rc.error
          tr.jLogger(root, path, logRecord(info, TrqDelete, rc.error))
          return err(rc.error)

      # Delete from DB
      let emptyTrie = api.deleteGenericData(mpt, root, path).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, root, path=($$path), error
        tr.jLogger(root, path, logRecord(info, TrqDelete, error))
        return err(error)

      # Log on journal
      tr.jLogger(root, path, tiRec)

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, root, path=($$path), emptyTrie
      ok emptyTrie

  tracerApi.deleteGenericTree =
    proc(mpt: AristoDbRef;
         root: VertexID;
        ): Result[void,AristoError] =
      const info = AristoApiProfDeleteGenericTreeFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Delete from DB
      api.deleteGenericTree(mpt, root).isOkOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, root, error
        tr.jLogger(root, logRecord(info, TrqDelete, error))
        return err(error)

      # Log on journal
      tr.jLogger(root, logRecord(info, TrqDelete))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, root
      ok()

  tracerApi.deleteStorageData =
    proc(mpt: AristoDbRef;
         accPath: Hash256;
         stoPath: Hash256;
        ): Result[bool,AristoError] =
      const info = AristoApiProfDeleteStorageDataFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB (for comprehensive log record)
      let tiRec = block:
        let rc = api.fetchStorageData(mpt, accPath, stoPath)
        if rc.isOk:
          logRecord(info, TrqDelete, rc.value)
        elif rc.error == FetchPathNotFound:
          logRecord(info, TrqDelete)
        else:
          when CoreDbNoisyCaptJournal:
            debug logTxt $info, level, accPath, stoPath, error=rc.error
          tr.jLogger(accPath, stoPath, logRecord(info, TrqDelete, rc.error))
          return err(rc.error)

      let emptyTrie = api.deleteStorageData(mpt, accPath, stoPath).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, accPath, stoPath, error
        tr.jLogger(accPath, stoPath, logRecord(info, TrqDelete, error))
        return err(error)

      # Log on journal
      tr.jLogger(accPath, stoPath, tiRec)

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, accPath, stoPath, emptyTrie
      ok emptyTrie

  tracerApi.deleteStorageTree =
    proc(mpt: AristoDbRef;
         accPath: Hash256;
        ): Result[void,AristoError] =
      const info = AristoApiProfDeleteStorageTreeFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Delete from DB
      api.deleteStorageTree(mpt, accPath).isOkOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, accPath, error
        tr.jLogger(accPath, logRecord(info, TrqDelete, error))
        return err(error)

      # Log on journal
      tr.jLogger(accPath, logRecord(info, TrqDelete))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, accPath
      ok()

  tracerApi.mergeAccountRecord =
    proc(mpt: AristoDbRef;
         accPath: Hash256;
         accRec: AristoAccount;
        ): Result[bool,AristoError] =
      const info = AristoApiProfMergeAccountRecordFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB (for comprehensive log record)
      let
        hadPath = api.hasPathAccount(mpt, accPath).valueOr:
          when CoreDbNoisyCaptJournal:
            debug logTxt $info, level, accPath, error
          tr.jLogger(accPath, logRecord(info, TrqAdd, error))
          return err(error)
        mode = if hadPath: TrqModify else: TrqAdd

      # Do the merge
      let updated = api.mergeAccountRecord(mpt, accPath, accRec).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, accPath, hadPath, error
        tr.jLogger(accPath, logRecord(info, mode, error))
        return err(error)

      # Log on journal
      tr.jLogger(accPath, logRecord(info, mode, accRec))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, accPath, accRec, hadPath, updated
      ok updated

  tracerApi.mergeGenericData =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
         data: openArray[byte];
        ): Result[bool,AristoError] =
      const info = AristoApiProfMergeGenericDataFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB (for comprehensive log record)
      let
        hadPath = api.hasPathGeneric(mpt, root, path).valueOr:
          when CoreDbNoisyCaptJournal:
            debug logTxt $info, level, root, path, error
          tr.jLogger(root, path, logRecord(info, TrqAdd, error))
          return err(error)
        mode = if hadPath: TrqModify else: TrqAdd

      # Do the merge
      let updated = api.mergeGenericData(mpt, root, path, data).valueOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, root, path, error
        tr.jLogger(root, path, logRecord(info, mode, error))
        return err(error)

      # Log on journal
      tr.jLogger(root, path, logRecord(info, mode, data))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, root, path, data=($$data), hadPath, updated
      ok updated

  tracerApi.mergeStorageData =
    proc(mpt: AristoDbRef;
         accPath: Hash256;
         stoPath: Hash256;
         stoData: UInt256;
        ): Result[void,AristoError] =
      const info = AristoApiProfMergeStorageDataFn

      when CoreDbNoisyCaptJournal:
        let level = tr.topLevel()

      # Find entry on DB (for comprehensive log record)
      let
        hadPath = api.hasPathStorage(mpt, accPath, stoPath).valueOr:
          when CoreDbNoisyCaptJournal:
            debug logTxt $info, level, accPath, stoPath, error
          tr.jLogger(accPath, stoPath, logRecord(info, TrqAdd, error))
          return err(error)
        mode = if hadPath: TrqModify else: TrqAdd

      # Do the merge
      api.mergeStorageData(mpt, accPath, stoPath,stoData).isOkOr:
        when CoreDbNoisyCaptJournal:
          debug logTxt $info, level, accPath, stoPath, error
        tr.jLogger(accPath, stoPath, logRecord(info, mode, error))
        return err(error)

      # Log on journal
      tr.jLogger(accPath, stoPath,  logRecord(info, mode, stoData))

      when CoreDbNoisyCaptJournal:
        debug logTxt $info, level, accPath, stoPath, stoData, hadPath
      ok()

  assert tr.ariSave != tr.db.ariApi
  assert tr.ariSave.deleteAccountRecord != tr.db.ariApi.deleteAccountRecord
  assert tr.ariSave.hasPathAccount == tr.db.ariApi.hasPathAccount

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc topInst*(tr: TraceRecorderRef): TraceLogInstRef =
  ## Get top level logger
  tr.log[^1]

func truncated*(log: TraceLogInstRef): bool =
  ## True if journal was truncated due to collecting too many entries
  log.truncated

func level*(log: TraceLogInstRef): int =
  ## Non-negative stack level of this log instance.
  log.level

func journal*(log: TraceLogInstRef): KeyedQueue[Blob,TraceDataItemRef] =
  ## Get the journal
  log.journal

func db*(log: TraceLogInstRef): CoreDbRef =
  ## Get database
  log.base.db

iterator kvtLog*(log: TraceLogInstRef): (Blob,TraceDataItemRef) =
  ## Extract `Kvt` journal
  for p in log.journal.nextPairs:
    let pfx = TracePfx(p.key[0])
    if pfx == TrpKvt:
      yield (p.key[1..^1], p.data)

proc kvtLogBlobs*(log: TraceLogInstRef): seq[(Blob,Blob)] =
  log.kvtLog.toSeq
     .filterIt(it[1].kind==TdtBlob)
     .mapIt((it[0],it[1].blob))

iterator ariLog*(log: TraceLogInstRef): (VertexID,Blob,TraceDataItemRef) =
  ## Extract `Aristo` journal
  for p in log.journal.nextPairs:
    let
      pfx = TracePfx(p.key[0])
      (root, key) = block:
        case pfx:
        of TrpAccounts,TrpStorage:
          (VertexID(1), p.key[1..^1])
        of TrpGeneric:
          (VertexID(p.key[1]), p.key[2..^1])
        else:
          continue
    yield (root, key, p.data)

proc pop*(log: TraceLogInstRef): bool =
  ## Reduce logger stack by the argument descriptor `log` which must be the
  ## top entry on the stack. The function returns `true` if the descriptor
  ## `log` was not the only one on stack and the stack was reduced by the
  ## top entry. Otherwise nothing is done and `false` returned.
  ##
  let tr = log.base
  doAssert log.level == tr.topLevel()
  if 1 < tr.log.len: # Always leave one instance on stack
    tr.log.setLen(tr.log.len - 1)
    return true

proc push*(tr: TraceRecorderRef) =
  ## Push overlay logger instance
  tr.log.add TraceLogInstRef(base: tr, level: tr.log.len)

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type TraceRecorderRef;     # Recorder desc to instantiate
    db: CoreDbRef;                # Database
      ): T =
  ## Constructor, create initial/base tracer descriptor
  result = T(db: db)
  result.push()
  result.kvtTraceRecorder()
  result.ariTraceRecorder()

proc restore*(tr: TraceRecorderRef) =
  ## Restore production API.
  tr.db.kvtApi = tr.kvtSave
  tr.db.ariApi = tr.ariSave
  tr[].reset

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

