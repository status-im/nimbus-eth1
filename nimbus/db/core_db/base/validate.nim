# Copyright (c) 2018 Status Research & Development GmbH
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
  MethodsDesc =
    CoreDxKvtRef |
    CoreDxMptRef | CoreDxPhkRef |
    CoreDxTxRef  | CoreDxTxID   |
    CoreDxCaptRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc validateMethodsDesc(msc: CoreDbMiscFns) =
  doAssert not msc.backendFn.isNil
  doAssert not msc.legacySetupFn.isNil

proc validateMethodsDesc(kvt: CoreDbKvtFns) =
  doAssert not kvt.backendFn.isNil
  doAssert not kvt.getFn.isNil
  doAssert not kvt.delFn.isNil
  doAssert not kvt.putFn.isNil
  doAssert not kvt.containsFn.isNil
  doAssert not kvt.pairsIt.isNil

proc validateMethodsDesc(fns: CoreDbMptFns) =
  doAssert not fns.backendFn.isNil
  doAssert not fns.getFn.isNil
  doAssert not fns.delFn.isNil
  doAssert not fns.putFn.isNil
  doAssert not fns.containsFn.isNil
  doAssert not fns.rootHashFn.isNil
  doAssert not fns.isPruningFn.isNil
  doAssert not fns.pairsIt.isNil
  doAssert not fns.replicateIt.isNil

proc validateConstructors(new: CoreDbConstructorFns) =
  doAssert not new.mptFn.isNil
  doAssert not new.legacyMptFn.isNil
  doAssert not new.getIdFn.isNil
  doAssert not new.beginFn.isNil
  doAssert not new.captureFn.isNil

# ------------
  
proc validateMethodsDesc(kvt: CoreDxKvtRef) =
  doAssert not kvt.isNil
  doAssert not kvt.parent.isNil
  kvt.methods.validateMethodsDesc

proc validateMethodsDesc(mpt: CoreDxMptRef) =
  doAssert not mpt.isNil
  doAssert not mpt.parent.isNil
  mpt.methods.validateMethodsDesc

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
  db.kvtRef.validateMethodsDesc
  db.new.validateConstructors
  db.methods.validateMethodsDesc

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc validate*(desc: MethodsDesc) =
  desc.validateMethodsDesc

proc validate*(db: CoreDbRef) =
  db.validateMethodsDesc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
