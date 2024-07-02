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
    # CoreDbCaptRef |
    CoreDbKvtRef | CoreDbCtxRef | CoreDbMptRef | CoreDbAccRef  | CoreDbTxRef

  ValidateDesc* =
    MethodsDesc | EphemMethodsDesc | CoreDbErrorRef |
    CoreDbKvtBaseRef | CoreDbAriBaseRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc validateSubDescRef(e: CoreDbErrorRef) =
  doAssert e.error != CoreDbErrorCode(0)
  doAssert not e.isNil
  doAssert not e.parent.isNil

proc validateSubDescRef(kb: CoreDbKvtBackendRef) =
  doAssert not kb.isNil
  doAssert not kb.parent.isNil
  doAssert not kb.kdb.isNil

proc validateSubDescRef(ab: CoreDbMptBackendRef | CoreDbAccBackendRef) =
  doAssert not ab.isNil
  doAssert not ab.parent.isNil
  doAssert not ab.adb.isNil

proc validateSubDescRef(kvt: CoreDbKvtRef) =
  doAssert not kvt.isNil
  doAssert not kvt.parent.isNil
  doAssert not kvt.kvt.isNil

proc validateSubDescRef(ctx: CoreDbCtxRef) =
  doAssert not ctx.isNil
  doAssert not ctx.parent.isNil
  doAssert not ctx.mpt.isNil

proc validateSubDescRef(mpt: CoreDbMptRef) =
  doAssert not mpt.isNil
  doAssert not mpt.parent.isNil

proc validateSubDescRef(acc: CoreDbAccRef) =
  doAssert not acc.isNil
  doAssert not acc.parent.isNil

when false: # currently disabled
  proc validateSubDescRef(cpt: CoreDbCaptRef) =
    doAssert not cpt.isNil
    doAssert not cpt.parent.isNil
    doAssert not cpt.methods.recorderFn.isNil
    doAssert not cpt.methods.getFlagsFn.isNil
    doAssert not cpt.methods.forgetFn.isNil

proc validateSubDescRef(tx: CoreDbTxRef) =
  doAssert not tx.isNil
  doAssert not tx.parent.isNil
  doAssert not tx.aTx.isNil
  doAssert not tx.kTx.isNil

proc validateSubDescRef(db: CoreDbRef) =
  doAssert not db.isNil
  doAssert db.dbType != CoreDbType(0)

proc validateSubDescRef(bd: CoreDbAriBaseRef) =
  doAssert not bd.parent.isNil
  doAssert not bd.api.isNil

proc validateSubDescRef(bd: CoreDbKvtBaseRef) =
  doAssert not bd.parent.isNil
  doAssert not bd.api.isNil
  doAssert not bd.kdb.isNil
  doAssert not bd.cache.isNil

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc validate*(dsc: ValidateDesc) =
  dsc.validateSubDescRef

proc validate*(db: CoreDbRef) =
  db.validateSubDescRef
  doAssert not db.kdbBase.isNil
  doAssert not db.adbBase.isNil
  doAssert not db.ctx.isNil

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
