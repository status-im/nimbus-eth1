# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  ./base_desc

proc validate*(ldg: LedgerRef) =
  doAssert ldg.ldgType != LedgerType(0)

  doAssert not ldg.extras.getMptFn.isNil

  doAssert not ldg.methods.accessListFn.isNil
  doAssert not ldg.methods.accessList2Fn.isNil
  doAssert not ldg.methods.accountExistsFn.isNil
  doAssert not ldg.methods.addBalanceFn.isNil
  doAssert not ldg.methods.addLogEntryFn.isNil
  doAssert not ldg.methods.beginSavepointFn.isNil
  doAssert not ldg.methods.clearStorageFn.isNil
  doAssert not ldg.methods.clearTransientStorageFn.isNil
  doAssert not ldg.methods.collectWitnessDataFn.isNil
  doAssert not ldg.methods.commitFn.isNil
  doAssert not ldg.methods.deleteAccountFn.isNil
  doAssert not ldg.methods.disposeFn.isNil
  doAssert not ldg.methods.getAccessListFn.isNil
  doAssert not ldg.methods.getAndClearLogEntriesFn.isNil
  doAssert not ldg.methods.getBalanceFn.isNil
  doAssert not ldg.methods.getCodeFn.isNil
  doAssert not ldg.methods.getCodeHashFn.isNil
  doAssert not ldg.methods.getCodeSizeFn.isNil
  doAssert not ldg.methods.getCommittedStorageFn.isNil
  doAssert not ldg.methods.getNonceFn.isNil
  doAssert not ldg.methods.getStorageFn.isNil
  doAssert not ldg.methods.getStorageRootFn.isNil
  doAssert not ldg.methods.getTransientStorageFn.isNil
  doAssert not ldg.methods.contractCollisionFn.isNil
  doAssert not ldg.methods.inAccessListFn.isNil
  doAssert not ldg.methods.inAccessList2Fn.isNil
  doAssert not ldg.methods.incNonceFn.isNil
  doAssert not ldg.methods.isDeadAccountFn.isNil
  doAssert not ldg.methods.isEmptyAccountFn.isNil
  doAssert not ldg.methods.isTopLevelCleanFn.isNil
  doAssert not ldg.methods.logEntriesFn.isNil
  doAssert not ldg.methods.makeMultiKeysFn.isNil
  doAssert not ldg.methods.persistFn.isNil
  doAssert not ldg.methods.ripemdSpecialFn.isNil
  doAssert not ldg.methods.rollbackFn.isNil
  doAssert not ldg.methods.safeDisposeFn.isNil
  doAssert not ldg.methods.selfDestruct6780Fn.isNil
  doAssert not ldg.methods.selfDestructFn.isNil
  doAssert not ldg.methods.selfDestructLenFn.isNil
  doAssert not ldg.methods.setBalanceFn.isNil
  doAssert not ldg.methods.setCodeFn.isNil
  doAssert not ldg.methods.setNonceFn.isNil
  doAssert not ldg.methods.setStorageFn.isNil
  doAssert not ldg.methods.setTransientStorageFn.isNil
  doAssert not ldg.methods.stateFn.isNil
  doAssert not ldg.methods.subBalanceFn.isNil

# End
