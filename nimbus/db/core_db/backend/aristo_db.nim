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
  std/tables,
  eth/common,
  ../../aristo as use_ari,
  ../../aristo/[aristo_walk, aristo_serialise],
  ../../kvt as use_kvt,
  ../../kvt/[kvt_init/memory_only, kvt_walk],
  ".."/[base, base/base_desc]

import
  ../../aristo/aristo_init/memory_only as aristo_memory_only

# Caveat:
#  additional direct include(s) -- not import(s) -- is placed near
#  the end of this source file

# Annotation helper(s)
{.pragma:  noRaise, gcsafe, raises: [].}
{.pragma: rlpRaise, gcsafe, raises: [CoreDbApiError].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toError(
    e: AristoError;
    base: CoreDbAriBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, CoreDbErrorRef(
    ctx:      info,
    isAristo: true,
    aErr:     e))

func toError(
    e: KvtError;
    base: CoreDbKvtBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, CoreDbErrorRef(
    ctx:      info,
    isAristo: false,
    kErr:     e))

# ------------------------------------------------------------------------------
# Private functions, free parking
# ------------------------------------------------------------------------------

when false:
  proc kvtForget(
      cKvt: CoreDbKvtRef;
      info: static[string];
        ): CoreDbRc[void] =
    ## Free parking here
    let
      base = cKvt.parent.kdbBase
      kvt = cKvt.kvt
    if kvt != base.kdb:
      let rc = base.api.forget(kvt)

      # There is not much that can be done in case of a `forget()` error.
      # So unmark it anyway.
      cKvt.kvt = KvtDbRef(nil)

      if rc.isErr:
        return err(rc.error.toError(base, info))
    ok()

  proc cptMethods(
      tracer: AristoTracerRef;
        ): CoreDbCaptFns =
    ## Free parking here --  currently disabled
    let
      tr = tracer         # So it can savely be captured
      db = tr.parent      # Will not change and can be captured
      log = tr.topInst()  # Ditto

    CoreDbCaptFns(
      recorderFn: proc(): CoreDbRef =
        db,

      logDbFn: proc(): TableRef[Blob,Blob] =
        log.kLog,

      getFlagsFn: proc(): set[CoreDbCaptFlags] =
        log.flags,

      forgetFn: proc() =
        if not tracer.pop():
          tr.parent.tracer = AristoTracerRef(nil)
          tr.restore())

# ------------------------------------------------------------------------------
# Private `Kvt` functions
# ------------------------------------------------------------------------------

func init(T: type CoreDbKvtBaseRef; db: CoreDbRef; kdb: KvtDbRef): T =
  result = db.bless CoreDbKvtBaseRef(
    api:       KvtApiRef.init(),
    kdb:       kdb,

    # Preallocated shared descriptor
    cache: db.bless CoreDbKvtRef(
      kvt:     kdb))

  when CoreDbEnableApiProfiling:
    let profApi = KvtApiProfRef.init(result.api, kdb.backend)
    result.api = profApi
    result.kdb.backend = profApi.be

# ------------------------------------------------------------------------------
# Private `Aristo` functions
# ------------------------------------------------------------------------------
   
func init(T: type CoreDbCtxRef; db: CoreDbRef, adb: AristoDbRef): T =
  ## Create initial context
  let ctx = CoreDbCtxRef(mpt: adb)

  when CoreDbEnableApiProfiling:
    let profApi = AristoApiProfRef.init(db.adbBase.api, adb.backend)
    result.api = profApi
    result.ctx.mpt.backend = profApi.be

  db.bless ctx

proc init(
    T: type CoreDbCtxRef;
    base: CoreDbAriBaseRef;
    colState: Hash256;
    colType: CoreDbColType;
      ): CoreDbRc[CoreDbCtxRef] =
  const info = "fromTxFn()"

  if colType.ord == 0:
    return err(use_ari.GenericError.toError(base, info, ColUnacceptable))
  let
    api = base.api
    vid = VertexID(colType)
    key = colState.to(HashKey)

    # Find `(vid,key)` on transaction stack
    inx = block:
      let rc = api.findTx(base.parent.ctx.CoreDbCtxRef.mpt, vid, key)
      if rc.isErr:
        return err(rc.error.toError(base, info))
      rc.value

    # Fork MPT descriptor that provides `(vid,key)`
    newMpt = block:
      let rc = api.forkTx(base.parent.ctx.CoreDbCtxRef.mpt, inx)
      if rc.isErr:
        return err(rc.error.toError(base, info))
      rc.value

  # Create new context
  ok(base.parent.bless CoreDbCtxRef(mpt: newMpt))

# ------------------------------------------------------------------------------
# Private tx and base methods
# ------------------------------------------------------------------------------

proc baseMethods(db: CoreDbRef): CoreDbBaseFns =
  let
    aBase = db.adbBase
    kBase = db.kdbBase

  when false: # currently disabled
    proc tracerSetup(flags: set[CoreDbCaptFlags]): CoreDbCaptRef =
      if db.tracer.isNil:
        db.tracer = AristoTracerRef(parent: db)
        db.tracer.init(kBase, aBase, flags)
      else:
        db.tracer.push(flags)
      CoreDbCaptRef(methods: db.tracer.cptMethods)

  proc persistent(bn: BlockNumber): CoreDbRc[void] =
    const info = "persistentFn()"

    block kvtBody:
      let
        kvt = kBase.kdb
        rc = kBase.api.persist(kvt)
      if rc.isOk or rc.error == TxPersistDelayed:
        # The latter clause is OK: Piggybacking on `Aristo` backend
        break kvtBody
      elif kBase.api.level(kvt) != 0:
        return err(rc.error.toError(kBase, info, TxPending))
      else:
        return err(rc.error.toError(kBase, info))

    block adbBody:
      let
        mpt = aBase.parent.ctx.CoreDbCtxRef.mpt
        rc = aBase.api.persist(mpt, bn)
      if rc.isOk:
        break adbBody
      elif aBase.api.level(mpt) != 0:
        return err(rc.error.toError(aBase, info, TxPending))
      else:
        return err(rc.error.toError(aBase, info))
    ok()

  proc errorPrintFn(e: CoreDbErrorRef): string =
    if not e.isNil:
      result = if e.isAristo: "Aristo" else: "Kvt"
      result &= ", ctx=" & $e.ctx & ", error="
      if e.isAristo:
        result &= $e.aErr
      else:
        result &= $e.kErr

  proc txBegin(): CoreDbTxRef =
    const info = "beginFn()"

    let aTx = block:
      let rc = aBase.api.txBegin(aBase.parent.ctx.CoreDbCtxRef.mpt)
      if rc.isErr:
        raiseAssert info & ": " & $rc.error
      rc.value

    let kTx = block:
      let rc = kBase.api.txBegin(kBase.kdb)
      if rc.isErr:
        raiseAssert info & ": " & $rc.error
      rc.value
                
    db.bless CoreDbTxRef(aTx: aTx, kTx: kTx)

  proc swapCtx(ctx: CoreDbCtxRef): CoreDbCtxRef =
    const info = "swapCtx()"
    
    doAssert not ctx.isNil
    result = aBase.parent.ctx

    # Set read-write access and install
    aBase.parent.ctx = CoreDbCtxRef(ctx)
    aBase.api.reCentre(aBase.parent.ctx.CoreDbCtxRef.mpt).isOkOr:
      raiseAssert info & " failed: " & $error


  CoreDbBaseFns(
    destroyFn: proc(eradicate: bool) =
      aBase.api.finish(aBase.parent.ctx.CoreDbCtxRef.mpt, eradicate)
      kBase.api.finish(kBase.kdb, eradicate),

    errorPrintFn: proc(e: CoreDbErrorRef): string =
      errorPrintFn(e),          

    newKvtFn: proc(): CoreDbRc[CoreDbKvtRef] =
      ok(kBase.cache),
 
    newCtxFn: proc(): CoreDbCtxRef =
      db.ctx,

    newCtxFromTxFn: proc(r: Hash256; k: CoreDbColType): CoreDbRc[CoreDbCtxRef] =
      CoreDbCtxRef.init(db.adbBase, r, k),

    swapCtxFn: proc(ctx: CoreDbCtxRef): CoreDbCtxRef =
      swapCtx(ctx),

    beginFn: proc(): CoreDbTxRef =
      txBegin(),

    # # currently disabled
    #  newCaptureFn: proc(flags:set[CoreDbCaptFlags]): CoreDbRc[CoreDbCaptRef] =
    #    ok(db.bless flags.tracerSetup()),

    persistentFn: proc(bn: BlockNumber): CoreDbRc[void] =
      persistent(bn))

# ------------------------------------------------------------------------------
# Public constructor and helper
# ------------------------------------------------------------------------------

proc create*(dbType: CoreDbType; kdb: KvtDbRef; adb: AristoDbRef): CoreDbRef =
  ## Constructor helper

  # Local extensions
  var db = CoreDbRef()
  db.adbBase = db.bless CoreDbAriBaseRef(api: AristoApiRef.init())
  db.kdbBase = CoreDbKvtBaseRef.init(db, kdb)
  db.ctx = CoreDbCtxRef.init(db, adb)

  # Base descriptor
  db.dbType = dbType
  db.methods = db.baseMethods()
  db.bless()

proc newAristoMemoryCoreDbRef*(): CoreDbRef =
  AristoDbMemory.create(
    KvtDbRef.init(use_kvt.MemBackendRef),
    AristoDbRef.init(use_ari.MemBackendRef))

proc newAristoVoidCoreDbRef*(): CoreDbRef =
  AristoDbVoid.create(
    KvtDbRef.init(use_kvt.VoidBackendRef),
    AristoDbRef.init(use_ari.VoidBackendRef))

# ------------------------------------------------------------------------------
# Public helpers, e.g. for direct backend access
# ------------------------------------------------------------------------------

func toAristoProfData*(
    db: CoreDbRef;
      ): tuple[aristo: AristoDbProfListRef, kvt: KvtDbProfListRef]  =
  when CoreDbEnableApiProfiling:
    result.aristo = db.CoreDbRef.adbBase.api.AristoApiProfRef.data
    result.kvt = db.CoreDbRef.kdbBase.api.KvtApiProfRef.data

func toAristoApi*(kvt: CoreDbKvtRef): KvtApiRef =
  return CoreDbRef(kvt.parent).kdbBase.api

func toAristoApi*(mpt: CoreDbMptRef): AristoApiRef =
  return mpt.parent.adbBase.api

func toAristo*(kBe: CoreDbKvtBackendRef): KvtDbRef =
  if not kBe.isNil:
    return kBe.kdb

func toAristo*(mBe: CoreDbMptBackendRef): AristoDbRef =
  if not mBe.isNil:
    return mBe.adb

func toAristo*(mBe: CoreDbAccBackendRef): AristoDbRef =
  if not mBe.isNil:
    return mBe.adb

proc toAristoSavedStateBlockNumber*(mBe: CoreDbMptBackendRef): BlockNumber =
  if not mBe.isNil:
    let
      base = mBe.parent.adbBase
      mpt = base.parent.ctx.CoreDbCtxRef.mpt
      be = mpt.backend
    if not be.isNil:
      let rc = base.api.fetchLastSavedState(mpt)
      if rc.isOk:
        return rc.value.serial.BlockNumber

# ------------------------------------------------------------------------------
# Public aristo iterators
# ------------------------------------------------------------------------------

include
  ./aristo_db/aristo_replicate

# ------------------------

iterator aristoKvtPairsVoid*(dsc: CoreDbKvtRef): (Blob,Blob) {.rlpRaise.} =
  let
    api = dsc.toAristoApi()
    p = api.forkTx(dsc.kvt,0).valueOrApiError "aristoKvtPairs()"
  defer: discard api.forget(p)
  for (k,v) in use_kvt.VoidBackendRef.walkPairs p:
    yield (k,v)

iterator aristoKvtPairsMem*(dsc: CoreDbKvtRef): (Blob,Blob) {.rlpRaise.} =
  let
    api = dsc.toAristoApi()
    p = api.forkTx(dsc.kvt,0).valueOrApiError "aristoKvtPairs()"
  defer: discard api.forget(p)
  for (k,v) in use_kvt.MemBackendRef.walkPairs p:
    yield (k,v)

iterator aristoMptPairs*(dsc: CoreDbMptRef): (Blob,Blob) {.noRaise.} =
  let
    api = dsc.parent.adbBase.api
    mpt = dsc.parent.ctx.mpt
  for (path,data) in mpt.rightPairsGeneric dsc.rootID:
    yield (api.pathAsBlob(path), data)

iterator aristoSlotPairs*(
    dsc: CoreDbAccRef;
    accPath: Hash256;
      ): (Blob,Blob)
      {.noRaise.} =
  let
    api = dsc.parent.adbBase.api
    mpt = dsc.parent.ctx.mpt
  for (path,data) in mpt.rightPairsStorage accPath:
    yield (api.pathAsBlob(path), data)

iterator aristoReplicateMem*(dsc: CoreDbMptRef): (Blob,Blob) {.rlpRaise.} =
  ## Instantiation for `MemBackendRef`
  for k,v in aristoReplicate[use_ari.MemBackendRef](dsc):
    yield (k,v)

iterator aristoReplicateVoid*(dsc: CoreDbMptRef): (Blob,Blob) {.rlpRaise.} =
  ## Instantiation for `VoidBackendRef`
  for k,v in aristoReplicate[use_ari.VoidBackendRef](dsc):
    yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
