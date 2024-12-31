# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  eth/common,
  results,
  unittest2,
  ../../nimbus/db/opts,
  ../../nimbus/db/core_db/backend/aristo_rocksdb,
  ../../nimbus/db/aristo/[
    aristo_check,
    aristo_desc,
    aristo_init/persistent,
    aristo_part,
    aristo_part/part_debug,
    aristo_tx],
  ../replay/xcheck,
  ./test_helpers

const
  testRootVid = VertexID(2)
    ## Need to reconfigure for the test, root ID 1 cannot be deleted as a trie

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc innerCleanUp(ps: var PartStateRef) =
  if not ps.isNil:
    ps.db.db.finish(eradicate=true)
    ps = PartStateRef(nil)

# -----------------------

proc saveToBackend(
    tx: var AristoTxRef;
    noisy: bool;
    debugID: int;
      ): bool =
  # var db = tx.to(AristoDbRef)

  # # Verify context: nesting level must be 2 (i.e. two transactions)
  # xCheck tx.level == 2

  # # Commit and hashify the current layer
  # block:
  #   let rc = tx.commit()
  #   xCheckRc rc.error == 0

  # block:
  #   let rc = db.txFrameTop()
  #   xCheckRc rc.error == 0
  #   tx = rc.value

  # # Verify context: nesting level must be 1 (i.e. one transaction)
  # xCheck tx.level == 1

  # block:
  #   let rc = db.checkBE()
  #   xCheckRc rc.error == (0,0)

  # # Commit and save to backend
  # block:
  #   let rc = tx.commit()
  #   xCheckRc rc.error == 0

  # block:
  #   let rc = db.txFrameTop()
  #   xCheckErr rc.value.level < 0 # force error

  # block:
  #   let rc = db.schedStow()
  #   xCheckRc rc.error == 0

  # # Update layers to original level
  # tx = db.txFrameBegin().value.to(AristoDbRef).txFrameBegin().value

  true

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testMergeProofAndKvpList*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                         # Rocks DB storage directory
    idPfx = "";
      ): bool {.deprecated.} =
  # TODO update for non-generic data
  # var
  #   ps = PartStateRef(nil)
  #   tx = AristoTxRef(nil)
  #   rootKey: Hash32
  # defer:
  #   if not ps.isNil:
  #     ps.db.finish(eradicate=true)

  # for n,w in list:

  #   # Start new database upon request
  #   if w.root != rootKey or w.proof.len == 0:
  #     ps.innerCleanUp()
  #     let db = block:
  #       # New DB with disabled filter slots management
  #       if 0 < rdbPath.len:
  #         let (dbOpts, cfOpts) = DbOptions.init().toRocksDb()
  #         let rc = AristoDbRef.init(RdbBackendRef, rdbPath,  DbOptions.init(), dbOpts, cfOpts, [])
  #         xCheckRc rc.error == 0
  #         rc.value()[0]
  #       else:
  #         AristoDbRef.init(MemBackendRef)
  #     ps = PartStateRef.init(db)

  #     # Start transaction (double frame for testing)
  #     tx = ps.db.txFrameBegin().value.to(AristoDbRef).txFrameBegin().value
  #     xCheck tx.isTop()

  #     # Update root
  #     rootKey = w.root

  #   if 0 < w.proof.len:
  #     let rc = ps.partPut(w.proof, ForceGenericPayload)
  #     xCheckRc rc.error == 0

  #   block:
  #     let rc = ps.check()
  #     xCheckRc rc.error == (0,0)

  #   for ltp in w.kvpLst:
  #     block:
  #       let rc = ps.partMergeGenericData(
  #         testRootVid, @(ltp.leafTie.path), ltp.payload.rawBlob)
  #       xCheckRc rc.error == 0
  #     block:
  #       let rc = ps.check()
  #       xCheckRc rc.error == (0,0)

  #   block:
  #     let saveBeOk = tx.saveToBackend(noisy=noisy, debugID=n)
  #     xCheck saveBeOk

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
