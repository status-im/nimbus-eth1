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
  results,
  ./kvt_init/init_common,
  ./[kvt_desc, kvt_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: KvtDbRef, parent: KvtTxRef): KvtTxRef =
  ## Starts a new transaction.
  let parent = if parent == nil: db.txRef else: parent
  KvtTxRef(
    db:     db,
    parent: parent,
  )

proc baseTxFrame*(db: KvtDbRef): KvtTxRef =
  db.txRef

proc dispose*(tx: KvtTxRef) =
  tx[].reset()

proc persist*(
    db: KvtDbRef;
    batch: PutHdlRef;
    txFrame: KvtTxRef;
      ) =
  if txFrame != db.txRef:
    # Consolidate the changes from the old to the new base going from the
    # bottom of the stack to avoid having to cascade each change through
    # the full stack
    assert txFrame.parent != nil
    for frame in txFrame.stack():
      if frame == db.txRef:
        continue
      mergeAndReset(db.txRef, frame)
      frame.dispose()

    # Put the now-merged contents in txFrame and make it the new base
    swap(db.txRef[], txFrame[])
    db.txRef = txFrame

  # Store structural single trie entries
  for k,v in txFrame.sTab:
    db.putKvpFn(batch, k, v)
  # TODO above, we only prepare the changes to the database but don't actually
  #      write them to disk - the code below that updates the frame should
  #      really run after things have been written (to maintain sync betweeen
  #      in-memory and on-disk state)

  # Done with txRef, all saved to backend
  txFrame.sTab.clear()

proc persist*(txFrame: KvtTxRef) =
  let
    kvt = txFrame.db
    kvtBatch = kvt.putBegFn()

  if kvtBatch.isOk():
    kvt.persist(kvtBatch[], txFrame)

    kvt.putEndFn(kvtBatch[]).isOkOr:
      raiseAssert $error
  else:
    discard kvtBatch.expect("should always be able to create batch")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
