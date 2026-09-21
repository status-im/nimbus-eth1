# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- write set helper
## ==========================
##
## A `KvtTxRef` collects the writes that belong together and is either flushed
## to the backend in one batch or dropped wholesale. There is no layering: the
## data a write set holds is invisible to every other write set until it is
## flushed, and reads that miss go straight to the backend.
##
{.push raises: [].}

import
  results,
  ./kvt_init/init_common,
  ./kvt_desc

when compileOption("threads"):
  import eth/common/hashes_rlp, eth/rlp, ../storage_types

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: KvtDbRef): KvtTxRef =
  ## Starts a new write set.
  KvtTxRef(db: db)

proc baseTxFrame*(db: KvtDbRef): KvtTxRef =
  db.txRef

proc dispose*(tx: KvtTxRef) =
  tx[].reset()

proc stage(db: KvtDbRef; batch: PutHdlRef; txFrame: KvtTxRef) =
  ## Add the contents of `txFrame` to `batch` and empty it.
  for k,v in txFrame.sTab:
    db.putKvpFn(batch, k, v)
    when compileOption("threads"):
      if k.isBlockNumberToHashKey():
        let number = k.blockNumberFromHashKey()
        if v.len == 0:
          db.blockHashes.del(number)
        else:
          try:
            db.blockHashes.put(number, rlp.decode(v, Hash32))
          except RlpError:
            db.blockHashes.del(number)
  # TODO above, we only prepare the changes to the database but don't actually
  #      write them to disk - the code below that updates the frame should
  #      really run after things have been written (to maintain sync betweeen
  #      in-memory and on-disk state)
  txFrame.sTab.clear()

proc persist*(
    db: KvtDbRef;
    batch: PutHdlRef;
    txFrame: KvtTxRef;
      ) =
  ## Stage everything that is pending for the next write: whatever was written
  ## straight to the shared base write set, then `txFrame` itself so that its
  ## values win on conflict. `txFrame` becomes the new base afterwards - both
  ## are empty by then, so this is a pointer swap and no data moves.
  if txFrame != db.txRef:
    db.stage(batch, db.txRef)

  db.stage(batch, txFrame)
  db.txRef = txFrame

proc persist*(txFrame: KvtTxRef) =
  ## Write the contents of `txFrame` to disk in a batch of its own, leaving it
  ## empty. Used for data that is known-good the moment it is produced and so
  ## needs no staging in memory.
  if txFrame.sTab.len == 0:
    return

  let
    kvt = txFrame.db
    kvtBatch = kvt.putBegFn()

  if kvtBatch.isOk():
    kvt.stage(kvtBatch[], txFrame)

    kvt.putEndFn(kvtBatch[]).isOkOr:
      raiseAssert $error
  else:
    discard kvtBatch.expect("should always be able to create batch")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
