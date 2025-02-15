# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Transaction frames helper
## ===================================
##
{.push raises: [].}

import
  ./[kvt_desc, kvt_layers]


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: KvtDbRef, parent: KvtTxRef): KvtTxRef =
  ## Starts a new transaction.
  ##
  ## Example:
  ## ::
  ##   proc doSomething(db: KvtDbRef) =
  ##     let tx = db.begin
  ##     defer: tx.rollback()
  ##     ... continue using db ...
  ##     tx.commit()
  ##

  let parent = if parent == nil: db.txRef else: parent
  KvtTxRef(
    db:     db,
    layer: LayerRef(),
    parent: parent,
  )

proc baseTxFrame*(db: KvtDbRef): KvtTxRef =
  db.txRef

proc dispose*(
    tx: KvtTxRef;
      ) =

  tx[].reset()

proc txFramePersist*(
    db: KvtDbRef;
    batch: PutHdlRef;
    txFrame: KvtTxRef;
      ) =
  let be = db.backend
  doAssert not be.isNil, "Persisting to backend requires ... a backend!"

  if txFrame != db.txRef:
    # Consolidate the changes from the old to the new base going from the
    # bottom of the stack to avoid having to cascade each change through
    # the full stack
    assert txFrame.parent != nil
    for frame in txFrame.stack():
      if frame == db.txRef:
        continue
      mergeAndReset(db.txRef.layer[], frame.layer[])
      frame.dispose()

    # Put the now-merged contents in txFrame and make it the new base
    swap(db.txRef[], txFrame[])
    db.txRef = txFrame

  # Store structural single trie entries
  for k,v in txFrame.layer.sTab:
    be.putKvpFn(batch, k, v)
  # TODO above, we only prepare the changes to the database but don't actually
  #      write them to disk - the code below that updates the frame should
  #      really run after things have been written (to maintain sync betweeen
  #      in-memory and on-disk state)

  txFrame.layer.sTab.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
