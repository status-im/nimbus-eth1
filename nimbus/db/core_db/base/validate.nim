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
    CoreDbKvtObj |
    CoreDbMptRef | CoreDbPhkRef |
    CoreDbTxRef  | CoreDbTxID   |
    CoreDbCaptRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc validateMethodsDesc(db: CoreDbRef) =
  doAssert not db.methods.legacySetupFn.isNil

proc validateMethodsDesc(kvt: CoreDbKvtObj) =
  doAssert kvt.dbType != CoreDbType(0)
  doAssert not kvt.methods.getFn.isNil
  doAssert not kvt.methods.maybeGetFn.isNil
  doAssert not kvt.methods.delFn.isNil
  doAssert not kvt.methods.putFn.isNil
  doAssert not kvt.methods.containsFn.isNil
  doAssert not kvt.methods.pairsIt.isNil

proc validateMethodsDesc(trie: CoreDbMptRef|CoreDbPhkRef) =
  doAssert not trie.parent.isNil
  doAssert not trie.methods.getFn.isNil
  doAssert not trie.methods.maybeGetFn.isNil
  doAssert not trie.methods.delFn.isNil
  doAssert not trie.methods.putFn.isNil
  doAssert not trie.methods.containsFn.isNil
  doAssert not trie.methods.rootHashFn.isNil
  doAssert not trie.methods.isPruningFn.isNil
  doAssert not trie.methods.pairsIt.isNil
  doAssert not trie.methods.replicateIt.isNil

proc validateMethodsDesc(cpt: CoreDbCaptRef) =
  doAssert not cpt.parent.isNil
  doAssert not cpt.methods.recorderFn.isNil
  doAssert not cpt.methods.getFlagsFn.isNil

proc validateMethodsDesc(tx: CoreDbTxRef) =
  doAssert not tx.parent.isNil
  doAssert not tx.methods.commitFn.isNil
  doAssert not tx.methods.rollbackFn.isNil
  doAssert not tx.methods.disposeFn.isNil
  doAssert not tx.methods.safeDisposeFn.isNil

proc validateMethodsDesc(id: CoreDbTxID) =
  doAssert not id.parent.isNil
  # doAssert not id.methods.setIdFn.isNil
  doAssert not id.methods.roWrapperFn.isNil

proc validateConstructors(new: CoreDbConstructors) =
  doAssert not new.mptFn.isNil
  doAssert not new.legacyMptFn.isNil
  doAssert not new.getIdFn.isNil
  doAssert not new.beginFn.isNil
  doAssert not new.captureFn.isNil

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc validate*(desc: MethodsDesc) =
  desc.validateMethodsDesc

proc validate*(db: CoreDbRef) =
  db.validateMethodsDesc
  db.kvtObj.validateMethodsDesc
  db.new.validateConstructors

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------