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
  ../../aristo,
  ./base_desc

type
  ValidateSubDesc* = CoreDbCtxRef | CoreDbTxRef # | CoreDbCaptRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc validateSubDescRef(ctx: CoreDbCtxRef) =
  doAssert not ctx.isNil
  doAssert not ctx.parent.isNil
  doAssert not ctx.mpt.isNil
  doAssert not ctx.kvt.isNil

proc validateSubDescRef(tx: CoreDbTxRef) =
  doAssert not tx.isNil
  doAssert not tx.ctx.isNil
  doAssert not tx.aTx.isNil
  doAssert not tx.kTx.isNil

when false: # currently disabled
  proc validateSubDescRef(cpt: CoreDbCaptRef) =
    doAssert not cpt.isNil
    doAssert not cpt.parent.isNil
    doAssert not cpt.methods.recorderFn.isNil
    doAssert not cpt.methods.getFlagsFn.isNil
    doAssert not cpt.methods.forgetFn.isNil

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc validate*(dsc: ValidateSubDesc) =
  dsc.validateSubDescRef

proc validate*(db: CoreDbRef) =
  doAssert not db.isNil
  doAssert db.dbType != CoreDbType(0)
  db.defCtx.validate

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
