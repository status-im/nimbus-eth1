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
  ./[kvt_desc, kvt_layers]


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: KvtDbRef, parent: KvtTxRef): Result[KvtTxRef,KvtError] =
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
  ok KvtTxRef(
    db:     db,
    layer: LayerRef(),
    parent: parent,
  )

proc baseTxFrame*(db: KvtDbRef): KvtTxRef =
  db.txRef

proc rollback*(
    tx: KvtTxRef;                     # Top transaction on database
      ): Result[void,KvtError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##

  tx.layer[] = Layer()
  ok()

proc commit*(
    tx: KvtTxRef;                     # Top transaction on database
      ): Result[void,KvtError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  doAssert tx.parent != nil, "don't commit base tx"

  mergeAndReset(tx.parent.layer[], tx.layer[])

  ok()

proc txFramePersist*(
    db: KvtDbRef;                     # Database
    batch: PutHdlRef;
      ) =
  ## Persistently store data onto backend database. If the system is running
  ## without a database backend, the function returns immediately with an
  ## error.
  ##
  ## The function merges all staged data from the top layer cache onto the
  ## backend stage area. After that, the top layer cache is cleared.
  ##
  ## Finally, the staged data are merged into the physical backend database
  ## and the staged data area is cleared. Wile performing this last step,
  ## the recovery journal is updated (if available.)
  ##
  let be = db.backend
  doAssert not be.isNil, "Persisting to backend requires ... a backend!"

  # Store structural single trie entries
  for k,v in db.txRef.layer.sTab:
    be.putKvpFn(batch, k, v)

  # TODO above, we only prepare the changes to the database but don't actually
  #      write them to disk - the code below that updates the frame should
  #      really run after things have been written (to maintain sync betweeen
  #      in-memory and on-disk state)

  # Done with txRef, all saved to backend
  db.txRef.layer.sTab.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
