# Copyright (c) 2023 Status Research & Development GmbH
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
    CoreDbBackendRef | CoreDbKvtBackendRef | CoreDbMptBackendRef |
    CoreDbAccBackendRef | CoreDbVidRef

  MethodsDesc =
    CoreDxKvtRef |
    CoreDxMptRef | CoreDxPhkRef | CoreDxAccRef  |
    CoreDxTxRef  | CoreDxTxID   |
    CoreDxCaptRef

  ValidateDesc* = MethodsDesc | EphemMethodsDesc | CoreDbErrorRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc validateMethodsDesc(base: CoreDbBaseFns) =
  doAssert not base.backendFn.isNil
  doAssert not base.destroyFn.isNil
  doAssert not base.vidHashFn.isNil
  doAssert not base.errorPrintFn.isNil
  doAssert not base.legacySetupFn.isNil
  doAssert not base.getRootFn.isNil
  doAssert not base.newKvtFn.isNil
  doAssert not base.newMptFn.isNil
  doAssert not base.newAccFn.isNil
  doAssert not base.getIdFn.isNil
  doAssert not base.beginFn.isNil
  doAssert not base.captureFn.isNil

proc validateMethodsDesc(kvt: CoreDbKvtFns) =
  doAssert not kvt.backendFn.isNil
  doAssert not kvt.getFn.isNil
  doAssert not kvt.delFn.isNil
  doAssert not kvt.putFn.isNil
  doAssert not kvt.hasKeyFn.isNil
  doAssert not kvt.pairsIt.isNil

proc validateMethodsDesc(fns: CoreDbMptFns) =
  doAssert not fns.backendFn.isNil
  doAssert not fns.fetchFn.isNil
  doAssert not fns.deleteFn.isNil
  doAssert not fns.mergeFn.isNil
  doAssert not fns.hasPathFn.isNil
  doAssert not fns.rootVidFn.isNil
  doAssert not fns.isPruningFn.isNil
  doAssert not fns.pairsIt.isNil
  doAssert not fns.replicateIt.isNil

proc validateMethodsDesc(fns: CoreDbAccFns) =
  doAssert not fns.backendFn.isNil
  doAssert not fns.fetchFn.isNil
  doAssert not fns.deleteFn.isNil
  doAssert not fns.mergeFn.isNil
  doAssert not fns.hasPathFn.isNil
  doAssert not fns.rootVidFn.isNil
  doAssert not fns.isPruningFn.isNil

# ------------

proc validateMethodsDesc(vid: CoreDbVidRef) =
  doAssert not vid.isNil
  doAssert not vid.parent.isNil
  doAssert vid.ready == true

proc validateMethodsDesc(e: CoreDbErrorRef) =
  doAssert e.error != CoreDbErrorCode(0)
  doAssert not e.isNil
  doAssert not e.parent.isNil

proc validateMethodsDesc(eph: EphemMethodsDesc) =
  doAssert not eph.isNil
  doAssert not eph.parent.isNil

proc validateMethodsDesc(kvt: CoreDxKvtRef) =
  doAssert not kvt.isNil
  doAssert not kvt.parent.isNil
  kvt.methods.validateMethodsDesc

proc validateMethodsDesc(mpt: CoreDxMptRef) =
  doAssert not mpt.isNil
  doAssert not mpt.parent.isNil
  mpt.methods.validateMethodsDesc

proc validateMethodsDesc(acc: CoreDxAccRef) =
  doAssert not acc.isNil
  doAssert not acc.parent.isNil
  acc.methods.validateMethodsDesc

proc validateMethodsDesc(phk: CoreDxPhkRef) =
  doAssert not phk.isNil
  doAssert not phk.fromMpt.isNil
  phk.methods.validateMethodsDesc

proc validateMethodsDesc(cpt: CoreDxCaptRef) =
  doAssert not cpt.isNil
  doAssert not cpt.parent.isNil
  doAssert not cpt.methods.recorderFn.isNil
  doAssert not cpt.methods.getFlagsFn.isNil

proc validateMethodsDesc(tx: CoreDxTxRef) =
  doAssert not tx.isNil
  doAssert not tx.parent.isNil
  doAssert not tx.methods.commitFn.isNil
  doAssert not tx.methods.rollbackFn.isNil
  doAssert not tx.methods.disposeFn.isNil
  doAssert not tx.methods.safeDisposeFn.isNil

proc validateMethodsDesc(id: CoreDxTxID) =
  doAssert not id.isNil
  doAssert not id.parent.isNil
  doAssert not id.methods.roWrapperFn.isNil

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
