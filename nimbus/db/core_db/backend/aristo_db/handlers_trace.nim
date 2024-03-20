# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[strutils, tables],
  eth/common,
  stew/byteutils,
  results,
  ../../../aristo as use_aristo,
  ../../../aristo/aristo_path,
  ../../../kvt as use_kvt,
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

  TracerLogInstRef* = ref object
    ## Logger instance
    level*: uint8
    flags*: set[CoreDbCaptFlags]
    kLog*: TableRef[Blob,Blob]
    mLog*: TableRef[LeafTie,CoreDbPayloadRef]

  TraceRecorderRef* = ref object of RootRef
    inst: seq[TracerLogInstRef]   ## Production stack for log database
    kdb: TraceKdbRecorder         ## Contains restore information
    adb: TraceAdbRecorder         ## Contains restore information

when EnableDebugLog:
  import chronicles

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toStr(key: openArray[byte]): string =
  key.toHex

func `$`(root: VertexID): string =
  let vid = root.uint64
  if 0 < vid:
    "$" & vid.toHex.strip(leading=true, trailing=false, chars={'0'})
  else:
    "$ø"

func `$`(pyl: PayloadRef): string =
  case pyl.pType:
  of RawData:
    pyl.rawBlob.toStr
  of RlpData:
    pyl.rlpBlob.toStr
  of AccountData:
    "<AccountData>"

func `$`(pyl: CoreDbPayloadRef): string =
  if 0 < pyl.blob.len:
    pyl.blob.toStr
  else:
    $pyl

func `$`(data: Blob): string =
  data.toStr

func `$`(lty: LeafTie): string =
  $lty.root & ":" & $lty.path

# -------------------------

func getOrVoid(tab: TableRef[Blob,Blob]; w: openArray[byte]): Blob =
  tab.getOrDefault(@w, EmptyBlob)

func getOrVoid(
    tab: TableRef[LeafTie,CoreDbPayloadRef];
    lty: LeafTie;
      ): CoreDbPayloadRef =
  tab.getOrDefault(lty, CoreDbPayloadRef(nil))

func leafTie(
    root: VertexID;
    path: openArray[byte];
      ): Result[LeafTie,(VertexID,AristoError)] =
  let tag = path.pathToTag.valueOr:
    return err((VertexID(root), error))
  ok LeafTie(root: root, path: tag)

func to(pyl: PayloadRef; T: type CoreDbPayloadRef): T =
  case pyl.pType:
  of RawData:
    T(pType: RawData, rawBlob: pyl.rawBlob)
  of RlpData:
    T(pType: RlpData, rlpBlob: pyl.rlpBlob)
  of AccountData:
    T(pType: AccountData, account:  pyl.account)

func to(data: openArray[byte]; T: type CoreDbPayloadRef): T =
  T(pType: RawData, rawBlob: @data)

proc update(
    pyl: CoreDbPayloadRef;
    api: AristoApiRef;
    mpt: AristoDbRef;
      ): Result[CoreDbPayloadRef,(VertexID,AristoError)] =
  if pyl.pType == AccountData:
    pyl.blob = block:
      let rc = api.serialise(mpt, pyl)
      if rc.isOk:
        rc.value
      else:
        ? api.hashify(mpt)
        ? api.serialise(mpt, pyl)
  ok(pyl)

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
        const logTxt = "trace get"

      # Try to fetch data from the stacked logger instances
      var (data, pos) = (EmptyBlob, -1)
      for level in (tr.inst.len-1).countDown(0):
        data = tr.inst[level].kLog.getOrVoid key
        if 0 < data.len:
          when EnableDebugLog:
            debug logTxt, level, log="get()", key=key.toStr, result=data.toStr
          pos = level
          break

      # Alternatively fetch data from the production DB instance
      if pos < 0:
        data = api.get(kvt, key).valueOr:
          when EnableDebugLog:
            debug logTxt, key=key.toStr, error
          return err(error) # No way

      # Data available, store in all top level instances
      for level in pos+1 ..< tr.inst.len:
        tr.inst[level].kLog[@key] = data
        when EnableDebugLog:
          debug logTxt, level, log="put()", key=key.toStr, result=data.toStr

      ok(data)

  tracerApi.del =
    proc(kvt: KvtDbRef; key: openArray[byte]): Result[void,KvtError] =
      when EnableDebugLog:
        const logTxt = "trace del"

      # Delete data on the stacked logger instances
      for level in (tr.inst.len-1).countDown(0):
        let flags = tr.inst[level].flags
        tr.inst[level].kLog.del @key
        when EnableDebugLog:
          debug logTxt, level, log="del()", flags, key=key.toStr
        if PersistDel notin flags:
          return ok()

      when EnableDebugLog:
        debug logTxt, key=key.toStr
      api.del(kvt, key)

  tracerApi.put =
    proc(kvt: KvtDbRef; key, data: openArray[byte]): Result[void,KvtError] =
      when EnableDebugLog:
        const logTxt = "trace put"

      # Store data on the stacked logger instances
      for level in (tr.inst.len-1).countDown(0):
        let flags = tr.inst[level].flags
        tr.inst[level].kLog[@key] = @data
        when EnableDebugLog:
          debug logTxt, level, log="put()",
            flags, key=key.toStr, data=data.toStr
        if PersistPut notin flags:
          return ok()

      when EnableDebugLog:
        debug logTxt, key=key.toStr, data=data.toStr
      api.put(kvt, key, data)

  tracerApi.hasKey =
    proc(kvt: KvtDbRef; key: openArray[byte]): Result[bool,KvtError] =
      when EnableDebugLog:
        const logTxt = "trace hasKey"

      # Try to fetch data from the stacked logger instances
      for level in (tr.inst.len-1).countDown(0):
        if tr.inst[level].kLog.hasKey @key:
          when EnableDebugLog:
            debug logTxt, level, log="get()", key=key.toStr, result=true
          return ok(true)

      # Alternatively fetch data from the production DB instance
      when EnableDebugLog:
        debug logTxt, key=key.toStr
      api.hasKey(kvt, key)

  result = TraceKdbRecorder(
    base:     base,
    savedApi: api)
  base.api = tracerApi
  assert result.savedApi != base.api


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
        const logTxt = "trace fetchPayload"

      let key = leafTie(root, path).valueOr:
        when EnableDebugLog:
          debug logTxt, root, path=path.toStr, error=error[1]
        return err(error)

      # Try to fetch data from the stacked logger instances
      var (pyl, pos) = (CoreDbPayloadRef(nil), -1)
      for level in (tr.inst.len-1).countDown(0):
        pyl = tr.inst[level].mLog.getOrVoid key
        if not pyl.isNil:
          pos = level
          when EnableDebugLog:
            debug logTxt, level, key, result=($pyl)
          break

      # Alternatively fetch data from the production DB instance
      if pyl.isNil:
        pyl = block:
          let rc = api.fetchPayload(mpt, root, path)
          if rc.isErr:
            when EnableDebugLog:
              debug logTxt, level=0, key, error=rc.error[1]
            return err(rc.error)
          rc.value.to(CoreDbPayloadRef)

        # For accounts payload serialise the data
        pyl = pyl.update(api, mpt).valueOr:
          when EnableDebugLog:
            debug logTxt, key, pyl, error=(error[1])
          return err(error)

      # Data and payload available, store in all top level instances
      for level in pos+1 ..< tr.inst.len:
        tr.inst[level].mLog[key] = pyl
        when EnableDebugLog:
          debug logTxt, level, log="put()", key, result=($pyl)

      ok(pyl)

  tracerApi.delete =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
         accPath: PathID;
           ): Result[bool,(VertexID,AristoError)] =
      when EnableDebugLog:
        const logTxt = "trace delete"

      let key = leafTie(root, path).valueOr:
        when EnableDebugLog:
          debug logTxt, root, path=path.toStr, error=error[1]
        return err(error)

      # Delete data on the stacked logger instances
      for level in (tr.inst.len-1).countDown(0):
        let flags = tr.inst[level].flags
        tr.inst[level].mLog.del key
        when EnableDebugLog:
          debug logTxt, level, log="del()", flags, key
        if PersistDel notin flags:
          return ok(false)

      when EnableDebugLog:
        debug logTxt, key, accPath
      api.delete(mpt, root, path, accPath)

  tracerApi.merge =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path, data: openArray[byte];
         accPath: PathID;
           ): Result[bool,AristoError] =
      when EnableDebugLog:
        const logTxt = "trace merge"

      let key = leafTie(root, path).valueOr:
        when EnableDebugLog:
          debug logTxt, root, path=path.toStr, error=error[1]
        return err(error[1])

      # Store data on the stacked logger instances
      let pyl = data.to(CoreDbPayloadRef)
      for level in (tr.inst.len-1).countDown(0):
        let flags = tr.inst[level].flags
        tr.inst[level].mLog[key] = pyl
        when EnableDebugLog:
          debug logTxt, level, log="put()", flags, key, data=($pyl)
        if PersistPut notin flags:
          return ok(false)

      when EnableDebugLog:
        debug logTxt, key, data=($pyl), accPath
      api.merge(mpt, root, path, data, accPath)

  tracerApi.mergePayload =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
         pyl: PayloadRef;
         accPath = VOID_PATH_ID;
           ): Result[bool,AristoError] =
      when EnableDebugLog:
        const logTxt = "trace mergePayload"

      let key = leafTie(root, path).valueOr:
        when EnableDebugLog:
          debug logTxt, root, path=path.toStr, error=error[1]
        return err(error[1])

      # For accounts payload add serialised version of the data to `pyl`
      var pyl = pyl.to(CoreDbPayloadRef).update(api, mpt).valueOr:
        when EnableDebugLog:
          debug logTxt, key, pyl, error=(error[1])
        return err(error[1])

      # Store data on the stacked logger instances
      for level in (tr.inst.len-1).countDown(0):
        let flags = tr.inst[level].flags
        tr.inst[level].mLog[key] = pyl
        when EnableDebugLog:
          debug logTxt, level, log="put()", flags, key, pyl
        if PersistPut notin flags:
          return ok(false)

      when EnableDebugLog:
        debug logTxt, key, pyl
      api.mergePayload(mpt, root, path, pyl, accPath)

  tracerApi.hasPath =
    proc(mpt: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
           ): Result[bool,(VertexID,AristoError)] =
      when EnableDebugLog:
        const logTxt = "trace hasPath"

      let key = leafTie(root, path).valueOr:
        when EnableDebugLog:
          debug logTxt, root, path=path.toStr, error=error[1]
        return err(error)

      # Try to fetch data from the stacked logger instances
      for level in (tr.inst.len-1).countDown(0):
        if tr.inst[level].mLog.hasKey key:
          when EnableDebugLog:
            debug logTxt, level, log="get()", key, result=true
          return ok(true)

      # Alternatively fetch data from the production DB instance
      when EnableDebugLog:
        debug logTxt, key
      api.hasPath(mpt, root, path)

  result = TraceAdbRecorder(
    base:     base,
    savedApi: api)
  base.api = tracerApi
  assert result.savedApi != base.api

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc topInst*(tr: TraceRecorderRef): TracerLogInstRef =
  ## Get top level KVT logger
  if not tr.isNil and 0 < tr.inst.len:
    result = tr.inst[^1]

proc pop*(tr: TraceRecorderRef): bool =
  ## Reduce logger stack, returns `true` on success. There will always be
  ## at least one logger left on stack.
  if 1 < tr.inst.len: # Always leave one instance on stack
    tr.inst.setLen(tr.inst.len - 1)
    return true

proc push*(
    tr: TraceRecorderRef;
    flags: set[CoreDbCaptFlags];
      ) =
  ## Push overlay logger instance
  if not tr.isNil and 0 < tr.inst.len:
    let stackLen = tr.inst.len.uint8
    doAssert stackLen < 254 # so length can be securely held as a `uint8`
    tr.inst.add TracerLogInstRef(
      level: stackLen + 1u8,
      kLog:  newTable[Blob,Blob](),
      mLog:  newTable[LeafTie,CoreDbPayloadRef](),
      flags: flags)

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc init*(
    db: TraceRecorderRef;         # Recorder desc to initialise
    kBase: KvtBaseRef;            # `Kvt` base descriptor
    aBase: AristoBaseRef;         # `Aristo` base descriptor
    flags: set[CoreDbCaptFlags];
      ) =
  ## Constructor, create initial/base tracer descriptor
  db.inst = @[TracerLogInstRef(
    level: 1,
    kLog:  newTable[Blob,Blob](),
    mLog:  newTable[LeafTie,CoreDbPayloadRef](),
    flags: flags)]
  db.kdb = db.traceRecorder kBase
  db.adb = db.traceRecorder aBase

proc restore*(db: TraceRecorderRef) =
  ## Restore production API, might be called directly or be invoked from the
  ## call-back handler.
  if 0 < db.inst.len:
    db.kdb.base.api = db.kdb.savedApi
    db.adb.base.api = db.adb.savedApi

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
