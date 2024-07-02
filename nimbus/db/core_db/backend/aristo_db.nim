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

  proc tracerSetup(flags: set[CoreDbCaptFlags]): CoreDbCaptRef =
    ## Free parking here --  currently disabled
    if db.tracer.isNil:
      db.tracer = AristoTracerRef(parent: db)
      db.tracer.init(kBase, aBase, flags)
    else:
      db.tracer.push(flags)
    CoreDbCaptRef(methods: db.tracer.cptMethods)

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
    db.adbBase.api = profApi
    adb.backend = profApi.be

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

# ------------------------------------------------------------------------------
# Public aristo iterators
# ------------------------------------------------------------------------------

include
  ./aristo_db/aristo_replicate

# ------------------------

iterator aristoKvtPairsVoid*(kvt: CoreDbKvtRef): (Blob,Blob) {.rlpRaise.} =
  let
    api = kvt.parent.kdbBase.api
    p = api.forkTx(kvt.kvt,0).valueOrApiError "aristoKvtPairs()"
  defer: discard api.forget(p)
  for (k,v) in use_kvt.VoidBackendRef.walkPairs p:
    yield (k,v)

iterator aristoKvtPairsMem*(kvt: CoreDbKvtRef): (Blob,Blob) {.rlpRaise.} =
  let
    api = kvt.parent.kdbBase.api
    p = api.forkTx(kvt.kvt,0).valueOrApiError "aristoKvtPairs()"
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
