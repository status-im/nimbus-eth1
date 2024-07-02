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
  std/[tables, typetraits],
  eth/common,
  ../../aristo as use_ari,
  ../../aristo/[aristo_walk, aristo_serialise],
  ../../kvt as use_kvt,
  ../../kvt/[kvt_init/memory_only, kvt_walk],
  ".."/[base, base/base_desc]

import
  ../../aristo/aristo_init/memory_only as aristo_memory_only

when CoreDbEnableApiJumpTable:
  discard
else:
  import
    ../../aristo/[aristo_desc, aristo_path, aristo_tx],
    ../../kvt/[kvt_desc, kvt_tx]

# Caveat:
#  additional direct include(s) -- not import(s) -- is placed near
#  the end of this source file

# Annotation helper(s)
{.pragma:  noRaise, gcsafe, raises: [].}
{.pragma: rlpRaise, gcsafe, raises: [CoreDbApiError].}

# ------------------------------------------------------------------------------
# Private functions, free parking
# ------------------------------------------------------------------------------

when false:
  func toError(e: AristoError; s: string; error = Unspecified): CoreDbErrorRef =
    CoreDbErrorRef(
      error:    error,
      ctx:      s,
      isAristo: true,
      aErr:     e)

  func toError(e: KvtError; s: string; error = Unspecified): CoreDbErrorRef =
    CoreDbErrorRef(
      error:    error,
      ctx:      s,
      isAristo: false,
      kErr:     e)

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

proc create*(dbType: CoreDbType; kvt: KvtDbRef; mpt: AristoDbRef): CoreDbRef =
  ## Constructor helper
  var db = CoreDbRef(dbType: dbType)
  db.defCtx = db.bless CoreDbCtxRef(mpt: mpt, kvt: kvt)

  when CoreDbEnableApiTracking:
    db.kvtApi = KvtApiRef.init()
    db.ariApi = AristoApiRef.init()

    when CoreDbEnableApiProfiling:
      block:
        let profApi = KvtApiProfRef.init(db.kvtApi, kvt.backend)
        db.kvtApi = profApi
        kvt.backend = profApi.be
      block:
        let profApi = AristoApiProfRef.init(db.ariApi, mpt.backend)
        db.ariApi = profApi
        mpt.backend = profApi.be
  bless db
  
proc newAristoMemoryCoreDbRef*(): CoreDbRef =
  result = AristoDbMemory.create(
    KvtDbRef.init(use_kvt.MemBackendRef),
    AristoDbRef.init(use_ari.MemBackendRef))

proc newAristoVoidCoreDbRef*(): CoreDbRef =
  AristoDbVoid.create(
    KvtDbRef.init(use_kvt.VoidBackendRef),
    AristoDbRef.init(use_ari.VoidBackendRef))

# ------------------------------------------------------------------------------
# Public aristo iterators
# ------------------------------------------------------------------------------

include
  ./aristo_replicate

# ------------------------

iterator aristoKvtPairsVoid*(kvt: CoreDbKvtRef): (Blob,Blob) {.rlpRaise.} =
  let p = kvt.call(forkTx, kvt.kvt, 0).valueOrApiError "aristoKvtPairsVoid()"
  defer: discard kvt.call(forget, p)
  for (k,v) in use_kvt.VoidBackendRef.walkPairs p:
    yield (k,v)

iterator aristoKvtPairsMem*(kvt: CoreDbKvtRef): (Blob,Blob) {.rlpRaise.} =
  let p = kvt.call(forkTx, kvt.kvt, 0).valueOrApiError "aristoKvtPairsMem()"
  defer: discard kvt.call(forget, p)
  for (k,v) in use_kvt.MemBackendRef.walkPairs p:
    yield (k,v)

iterator aristoMptPairs*(mpt: CoreDbMptRef): (Blob,Blob) {.noRaise.} =
  for (path,data) in mpt.mpt.rightPairsGeneric mpt.rootID:
    yield (mpt.call(pathAsBlob, path), data)

iterator aristoSlotPairs*(
    acc: CoreDbAccRef;
    accPath: Hash256;
      ): (Blob,Blob)
      {.noRaise.} =
  for (path,data) in acc.mpt.rightPairsStorage accPath:
    yield (acc.call(pathAsBlob, path), data)

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
