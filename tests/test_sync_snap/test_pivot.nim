# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester and TDD environment

import
  eth/[common, p2p],
  unittest2,
  ../../nimbus/db/select_backend,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[snapdb_desc, snapdb_pivot]

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_pivotStoreRead*(
    accKeys: seq[NodeKey];
    cdb: ChainDb;
      ) =
  ## Storing/retrieving items on persistent pivot/checkpoint registry
  let
    dbBase = SnapDbRef.init(cdb)
    processed = @[(1.to(NodeTag),2.to(NodeTag)),
                  (4.to(NodeTag),5.to(NodeTag)),
                  (6.to(NodeTag),7.to(NodeTag))]
    slotAccounts = seq[NodeKey].default
  for n in 0 ..< accKeys.len:
    let w = accKeys[n]
    check dbBase.savePivot(
      SnapDbPivotRegistry(
        header:       BlockHeader(stateRoot: w.to(Hash256)),
        nAccounts:    n.uint64,
        nSlotLists:   n.uint64,
        processed:    processed,
        slotAccounts: slotAccounts)).isOk
    # verify latest state root
    block:
      let rc = dbBase.recoverPivot()
      check rc.isOk
      if rc.isOk:
        check rc.value.nAccounts == n.uint64
        check rc.value.nSlotLists == n.uint64
        check rc.value.processed == processed
        # Stop gossiping (happens whith corrupted database)
        if rc.value.nAccounts != n.uint64 or
           rc.value.nSlotLists != n.uint64 or
           rc.value.processed != processed:
          return
  for n in 0 ..< accKeys.len:
    let w = accKeys[n]
    block:
      let rc = dbBase.recoverPivot(w)
      check rc.isOk
      if rc.isOk:
        check rc.value.nAccounts == n.uint64
        check rc.value.nSlotLists == n.uint64
    # Update record in place
    check dbBase.savePivot(
      SnapDbPivotRegistry(
        header:       BlockHeader(stateRoot: w.to(Hash256)),
        nAccounts:    n.uint64,
        nSlotLists:   0,
        processed:    @[],
        slotAccounts: @[])).isOk
    block:
      let rc = dbBase.recoverPivot(w)
      check rc.isOk
      if rc.isOk:
        check rc.value.nAccounts == n.uint64
        check rc.value.nSlotLists == 0
        check rc.value.processed == seq[(NodeTag,NodeTag)].default

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
