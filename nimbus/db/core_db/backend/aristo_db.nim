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
  ../../aristo/aristo_walk,
  ../../kvt as use_kvt,
  ../../kvt/[kvt_init/memory_only, kvt_walk],
  ".."/[base, base/base_desc],
  ./aristo_db/[common_desc, handlers_aristo, handlers_kvt]

import
  ../../aristo/aristo_init/memory_only as aristo_memory_only

# Caveat:
#  additional direct include(s) -- not import(s) -- is placed near
#  the end of this source file

# Annotation helper(s)
{.pragma:  noRaise, gcsafe, raises: [].}
{.pragma: rlpRaise, gcsafe, raises: [AristoApiRlpError].}

export
  AristoApiRlpError,
  AristoCoreDbKvtBE,
  isAristo

type
  AristoCoreDbRef* = ref object of CoreDbRef
    ## Main descriptor
    kdbBase: KvtBaseRef                      ## Kvt subsystem
    adbBase: AristoBaseRef                   ## Aristo subsystem
    #tracer: AristoTracerRef                  ## Currently active recorder

  #AristoTracerRef = ref object of TraceRecorderRef
  #  ## Sub-handle for tracer
  #  parent: AristoCoreDbRef

proc newAristoVoidCoreDbRef*(): CoreDbRef {.noRaise.}

# ------------------------------------------------------------------------------
# Private tx and base methods
# ------------------------------------------------------------------------------

proc txMethods(
    db: AristoCoreDbRef;
    aTx: AristoTxRef;
    kTx: KvtTxRef;
     ): CoreDbTxFns =
  ## To be constructed by some `CoreDbBaseFns` function
  let
    adbBase = db.adbBase
    kdbBase = db.kdbBase

    adbApi = adbBase.api
    kdbApi = kdbBase.api

  CoreDbTxFns(
    levelFn: proc(): int =
      aTx.level,

    commitFn: proc() =
      const info = "commitFn()"
      adbApi.commit(aTx).isOkOr:
        raiseAssert info & ": " & $error
      kdbApi.commit(kTx).isOkOr:
        raiseAssert info & ": " & $error
      discard,

    rollbackFn: proc() =
      const info = "rollbackFn()"
      adbApi.rollback(aTx).isOkOr:
        raiseAssert info & ": " & $error
      kdbApi.rollback(kTx).isOkOr:
        raiseAssert info & ": " & $error
      discard,

    disposeFn: proc() =
      const info =  "disposeFn()"
      if adbApi.isTop(aTx):
        adbApi.rollback(aTx).isOkOr:
          raiseAssert info & ": " & $error
      if kdbApi.isTop(kTx):
        kdbApi.rollback(kTx).isOkOr:
          raiseAssert info & ": " & $error
      discard)

when false: # currently disabled
  proc cptMethods(
      tracer: AristoTracerRef;
        ): CoreDbCaptFns =
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


proc baseMethods(db: AristoCoreDbRef): CoreDbBaseFns =
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

  proc persistent(bn: Opt[BlockNumber]): CoreDbRc[void] =
    const info = "persistentFn()"
    let sid =
      if bn.isNone: 0u64
      else: bn.unsafeGet
    ? kBase.persistent info
    ? aBase.persistent(sid, info)
    ok()

  CoreDbBaseFns(
    destroyFn: proc(eradicate: bool) =
      aBase.destroy(eradicate)
      kBase.destroy(eradicate),

    levelFn: proc(): int =
      aBase.getLevel,

    errorPrintFn: proc(e: CoreDbErrorRef): string =
      e.errorPrint(),

    newKvtFn: proc(): CoreDbRc[CoreDbKvtRef] =
      kBase.newKvtHandler("newKvtFn()"),

    newCtxFn: proc(): CoreDbCtxRef =
      aBase.ctx,

    newCtxFromTxFn: proc(r: Hash256; k: CoreDbColType): CoreDbRc[CoreDbCtxRef] =
      CoreDbCtxRef.init(db.adbBase, r, k),

    swapCtxFn: proc(ctx: CoreDbCtxRef): CoreDbCtxRef =
      aBase.swapCtx(ctx),

    beginFn: proc(): CoreDbTxRef =
      const info = "beginFn()"
      let
        aTx = aBase.txBegin info
        kTx = kBase.txBegin info
        dsc = CoreDbTxRef(methods: db.txMethods(aTx, kTx))
      db.bless(dsc),

    # # currently disabled
    #  newCaptureFn: proc(flags:set[CoreDbCaptFlags]): CoreDbRc[CoreDbCaptRef] =
    #    ok(db.bless flags.tracerSetup()),

    persistentFn: proc(bn: Opt[BlockNumber]): CoreDbRc[void] =
      persistent(bn))

# ------------------------------------------------------------------------------
# Public constructor and helper
# ------------------------------------------------------------------------------

proc create*(dbType: CoreDbType; kdb: KvtDbRef; adb: AristoDbRef): CoreDbRef =
  ## Constructor helper

  # Local extensions
  var db = AristoCoreDbRef()
  db.adbBase = AristoBaseRef.init(db, adb)
  db.kdbBase = KvtBaseRef.init(db, kdb)

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
    if db.isAristo:
      result.aristo = db.AristoCoreDbRef.adbBase.api.AristoApiProfRef.data
      result.kvt = db.AristoCoreDbRef.kdbBase.api.KvtApiProfRef.data

func toAristoApi*(kvt: CoreDbKvtRef): KvtApiRef =
  if kvt.parent.isAristo:
    return AristoCoreDbRef(kvt.parent).kdbBase.api

func toAristoApi*(mpt: CoreDbMptRef): AristoApiRef =
  if mpt.parent.isAristo:
    return mpt.to(AristoApiRef)

func toAristo*(kBe: CoreDbKvtBackendRef): KvtDbRef =
  if not kBe.isNil and kBe.parent.isAristo:
    return kBe.AristoCoreDbKvtBE.kdb

func toAristo*(mBe: CoreDbMptBackendRef): AristoDbRef =
  if not mBe.isNil and mBe.parent.isAristo:
    return mBe.AristoCoreDbMptBE.adb

func toAristo*(mBe: CoreDbAccBackendRef): AristoDbRef =
  if not mBe.isNil and mBe.parent.isAristo:
    return mBe.AristoCoreDbAccBE.adb

proc toAristoSavedStateBlockNumber*(
    mBe: CoreDbMptBackendRef;
      ): tuple[stateRoot: Hash256, blockNumber: BlockNumber] =
  if not mBe.isNil and mBe.parent.isAristo:
    let rc = mBe.parent.AristoCoreDbRef.adbBase.getSavedState()
    if rc.isOk:
      return (rc.value.src.to(Hash256), rc.value.serial.BlockNumber)
  (EMPTY_ROOT_HASH, 0.BlockNumber)

# ------------------------------------------------------------------------------
# Public aristo iterators
# ------------------------------------------------------------------------------

include
  ./aristo_db/aristo_replicate

# ------------------------

iterator aristoKvtPairsVoid*(dsc: CoreDbKvtRef): (Blob,Blob) {.rlpRaise.} =
  let
    api = dsc.toAristoApi()
    p = api.forkTx(dsc.to(KvtDbRef),0).valueOrApiError "aristoKvtPairs()"
  defer: discard api.forget(p)
  for (k,v) in use_kvt.VoidBackendRef.walkPairs p:
    yield (k,v)

iterator aristoKvtPairsMem*(dsc: CoreDbKvtRef): (Blob,Blob) {.rlpRaise.} =
  let
    api = dsc.toAristoApi()
    p = api.forkTx(dsc.to(KvtDbRef),0).valueOrApiError "aristoKvtPairs()"
  defer: discard api.forget(p)
  for (k,v) in use_kvt.MemBackendRef.walkPairs p:
    yield (k,v)

iterator aristoMptPairs*(dsc: CoreDbMptRef): (Blob,Blob) {.noRaise.} =
  let
    api = dsc.to(AristoApiRef)
    mpt = dsc.to(AristoDbRef)
  for (path,data) in mpt.rightPairsGeneric dsc.rootID:
    yield (api.pathAsBlob(path), data)

iterator aristoSlotPairs*(
    dsc: CoreDbAccRef;
    accPath: openArray[byte];
      ): (Blob,Blob)
      {.noRaise.} =
  let
    api = dsc.to(AristoApiRef)
    mpt = dsc.to(AristoDbRef)
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
