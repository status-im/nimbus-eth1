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
  std/typetraits,
  eth/common,
  stew/byteutils,
  ../../../aristo,
  ../../../aristo/aristo_desc,
  ../../base,
  ../../base/base_desc

static:
  doAssert high(CoreDbColType).ord < LEAST_FREE_VID

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

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

proc getSavedState*(base: CoreDbAriBaseRef): Result[SavedState,void] =
  let
    mpt = base.parent.ctx.CoreDbCtxRef.mpt
    be = mpt.backend
  if not be.isNil:
    let rc = base.api.fetchLastSavedState(mpt)
    if rc.isOk:
      return ok(rc.value)
  err()

# ---------------------

proc txBegin*(
    base: CoreDbAriBaseRef;
    info: static[string];
      ): AristoTxRef =
  let rc = base.api.txBegin(base.parent.ctx.CoreDbCtxRef.mpt)
  if rc.isErr:
    raiseAssert info & ": " & $rc.error
  rc.value

proc getLevel*(base: CoreDbAriBaseRef): int =
  base.api.level(base.parent.ctx.CoreDbCtxRef.mpt)

# ---------------------

proc swapCtx*(base: CoreDbAriBaseRef; ctx: CoreDbCtxRef): CoreDbCtxRef =
  doAssert not ctx.isNil
  result = base.parent.ctx

  # Set read-write access and install
  base.parent.ctx = CoreDbCtxRef(ctx)
  base.api.reCentre(base.parent.ctx.CoreDbCtxRef.mpt).isOkOr:
    raiseAssert "swapCtx() failed: " & $error


proc persistent*(
    base: CoreDbAriBaseRef;
    fid: uint64;
    info: static[string];
      ): CoreDbRc[void] =
  let
    api = base.api
    mpt = base.parent.ctx.CoreDbCtxRef.mpt
    rc = api.persist(mpt, fid)
  if rc.isOk:
    ok()
  elif api.level(mpt) == 0:
    err(rc.error.toError(base, info))
  else:
    err(rc.error.toError(base, info, TxPending))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc destroy*(base: CoreDbAriBaseRef; eradicate: bool) =
  base.api.finish(base.parent.ctx.CoreDbCtxRef.mpt, eradicate)

func init*(T: type CoreDbCtxRef; db: CoreDbRef, adb: AristoDbRef): T =
  ## Create initial context
  let ctx = CoreDbCtxRef(mpt: adb)

  when CoreDbEnableApiProfiling:
    let profApi = AristoApiProfRef.init(db.adbBase.api, adb.backend)
    result.api = profApi
    result.ctx.mpt.backend = profApi.be

  db.bless ctx


proc init*(
    T: type CoreDbCtxRef;
    base: CoreDbAriBaseRef;
    colState: Hash256;
    colType: CoreDbColType;
      ): CoreDbRc[CoreDbCtxRef] =
  const info = "fromTxFn()"

  if colType.ord == 0:
    return err(aristo.GenericError.toError(base, info, ColUnacceptable))
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
