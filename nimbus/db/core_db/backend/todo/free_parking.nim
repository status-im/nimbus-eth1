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
  eth/common,
  ../../aristo as use_ari,
  ../../aristo/[aristo_walk],
  ../../kvt as use_kvt,
  ../../kvt/[kvt_init/memory_only, kvt_walk],
  ".."/[base, base/base_desc]

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
  func toError(e: AristoError; s: string; error = Unspecified): CoreDbError =
    CoreDbError(
      error:    error,
      ctx:      s,
      isAristo: true,
      aErr:     e)

  func toError(e: KvtError; s: string; error = Unspecified): CoreDbError =
    CoreDbError(
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
# End
# ------------------------------------------------------------------------------
