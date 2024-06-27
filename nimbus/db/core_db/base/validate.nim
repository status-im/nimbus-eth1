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
  ./base_desc

type
  EphemMethodsDesc =
    CoreDbKvtBackendRef | CoreDbMptBackendRef | CoreDbAccBackendRef

  MethodsDesc =
    CoreDbKvtRef |
    CoreDbCtxRef | CoreDbMptRef | CoreDbAccRef  |
    CoreDbTxRef  |
    CoreDbCaptRef

  ValidateDesc* = MethodsDesc | EphemMethodsDesc | CoreDbErrorRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc validateMethodsDesc(base: CoreDbBaseFns) =
  doAssert not base.destroyFn.isNil
  doAssert not base.errorPrintFn.isNil
  doAssert not base.levelFn.isNil
  doAssert not base.newKvtFn.isNil
  doAssert not base.newCtxFn.isNil
  doAssert not base.newCtxFromTxFn.isNil
  doAssert not base.swapCtxFn.isNil
  doAssert not base.beginFn.isNil
  # doAssert not base.newCaptureFn.isNil # currently disabled
  doAssert not base.persistentFn.isNil

proc validateMethodsDesc(kvt: CoreDbKvtFns) =
  doAssert not kvt.backendFn.isNil
  doAssert not kvt.getFn.isNil
  doAssert not kvt.lenFn.isNil
  doAssert not kvt.delFn.isNil
  doAssert not kvt.putFn.isNil
  doAssert not kvt.hasKeyFn.isNil
  doAssert not kvt.forgetFn.isNil

proc validateMethodsDesc(ctx: CoreDbCtxFns) =
  doAssert not ctx.getAccountsFn.isNil
  doAssert not ctx.getColumnFn.isNil
  doAssert not ctx.forgetFn.isNil

proc validateMethodsDesc(fns: CoreDbMptFns) =
  doAssert not fns.backendFn.isNil
  doAssert not fns.fetchFn.isNil
  doAssert not fns.deleteFn.isNil
  doAssert not fns.mergeFn.isNil
  doAssert not fns.hasPathFn.isNil
  doAssert not fns.stateFn.isNil

proc validateMethodsDesc(fns: CoreDbAccFns) =
  doAssert not fns.backendFn.isNil
  doAssert not fns.fetchFn.isNil
  doAssert not fns.clearStorageFn.isNil
  doAssert not fns.deleteFn.isNil
  doAssert not fns.hasPathFn.isNil
  doAssert not fns.mergeFn.isNil
  doAssert not fns.stateFn.isNil

  doAssert not fns.slotFetchFn.isNil
  doAssert not fns.slotDeleteFn.isNil
  doAssert not fns.slotHasPathFn.isNil
  doAssert not fns.slotMergeFn.isNil
  doAssert not fns.slotStateFn.isNil
  doAssert not fns.slotStateEmptyFn.isNil

# ------------

proc validateMethodsDesc(e: CoreDbErrorRef) =
  doAssert e.error != CoreDbErrorCode(0)
  doAssert not e.isNil
  doAssert not e.parent.isNil

proc validateMethodsDesc(eph: EphemMethodsDesc) =
  doAssert not eph.isNil
  doAssert not eph.parent.isNil

proc validateMethodsDesc(kvt: CoreDbKvtRef) =
  doAssert not kvt.isNil
  doAssert not kvt.parent.isNil
  kvt.methods.validateMethodsDesc

proc validateMethodsDesc(ctx: CoreDbCtxRef) =
  doAssert not ctx.isNil
  doAssert not ctx.parent.isNil
  ctx.methods.validateMethodsDesc

proc validateMethodsDesc(mpt: CoreDbMptRef) =
  doAssert not mpt.isNil
  doAssert not mpt.parent.isNil
  mpt.methods.validateMethodsDesc

proc validateMethodsDesc(acc: CoreDbAccRef) =
  doAssert not acc.isNil
  doAssert not acc.parent.isNil
  acc.methods.validateMethodsDesc

when false: # currently disabled
  proc validateMethodsDesc(cpt: CoreDbCaptRef) =
    doAssert not cpt.isNil
    doAssert not cpt.parent.isNil
    doAssert not cpt.methods.recorderFn.isNil
    doAssert not cpt.methods.getFlagsFn.isNil
    doAssert not cpt.methods.forgetFn.isNil

proc validateMethodsDesc(tx: CoreDbTxRef) =
  doAssert not tx.isNil
  doAssert not tx.parent.isNil
  doAssert not tx.methods.levelFn.isNil
  doAssert not tx.methods.commitFn.isNil
  doAssert not tx.methods.rollbackFn.isNil
  doAssert not tx.methods.disposeFn.isNil

proc validateMethodsDesc(db: CoreDbRef) =
  doAssert not db.isNil
  doAssert db.dbType != CoreDbType(0)
  db.methods.validateMethodsDesc

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc validate*(dsc: ValidateDesc) =
  dsc.validateMethodsDesc

proc validate*(db: CoreDbRef) =
  db.validateMethodsDesc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
