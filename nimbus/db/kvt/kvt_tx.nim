# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Transaction interface
## ===============================
##
{.push raises: [].}

import
  results,
  ./kvt_tx/[tx_fork, tx_frame, tx_stow],
  ./kvt_desc

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func txTop*(db: KvtDbRef): Result[KvtTxRef,KvtError] =
  ## Getter, returns top level transaction if there is any.
  db.txFrameTop()

func isTop*(tx: KvtTxRef): bool =
  ## Getter, returns `true` if the argument `tx` referes to the current top
  ## level transaction.
  tx.txFrameIsTop()

func level*(tx: KvtTxRef): int =
  ## Getter, positive nesting level of transaction argument `tx`
  tx.txFrameLevel()

func level*(db: KvtDbRef): int =
  ## Getter, non-negative nesting level (i.e. number of pending transactions)
  db.txFrameLevel()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(tx: KvtTxRef; T: type[KvtDbRef]): T =
  ## Getter, retrieves the parent database descriptor from argument `tx`
  tx.db

func toKvtDbRef*(tx: KvtTxRef): KvtDbRef =
  ## Same as `.to(KvtDbRef)`
  tx.db

proc forkTx*(
    db: KvtDbRef;
    backLevel: int;                   # Backward location of transaction
      ): Result[KvtDbRef,KvtError] =
  ## Fork a new descriptor obtained from parts of the argument database
  ## as described by arguments `db` and `backLevel`.
  ##
  ## If the argument `backLevel` is non-negative, the forked descriptor will
  ## provide the database view where the first `backLevel` transaction layers
  ## are stripped and the remaing layers are squashed into a single transaction.
  ##
  ## If `backLevel` is `-1`, a database descriptor with empty transaction
  ## layers will be provided where the `roFilter` between database and
  ## transaction layers are kept in place.
  ##
  ## If `backLevel` is `-2`, a database descriptor with empty transaction
  ## layers will be provided without an `roFilter`.
  ##
  ## The returned database descriptor will always have transaction level one.
  ## If there were no transactions that could be squashed, an empty
  ## transaction is added.
  ##
  ## Use `kvt_desc.forget()` to clean up this descriptor.
  ##
  # Fork top layer (with or without pending transaction)?
  if backLevel == 0:
    return db.txForkTop()

  # Fork bottom layer (=> 0 < db.stack.len)
  if backLevel == db.stack.len:
    return db.txForkBase()

  # Inspect transaction stack
  if 0 < backLevel:
    var tx = db.txRef
    if tx.isNil or db.stack.len < backLevel:
      return err(TxLevelTooDeep)

    # Fetch tx of level `backLevel` (seed to skip some items)
    for _ in 0 ..< backLevel:
      tx = tx.parent
      if tx.isNil:
        return err(TxStackGarbled)
    return tx.txFork()

  # Plain fork, include `roFilter`
  if backLevel == -1:
    let xb = ? db.fork()
    discard xb.txFrameBegin()
    return ok(xb)

  # Plain fork, unfiltered backend
  if backLevel == -2:
    let xb = ? db.fork()
    discard xb.txFrameBegin()
    return ok(xb)

  err(TxLevelUseless)

# ------------------------------------------------------------------------------
# Public functions: Transaction frame
# ------------------------------------------------------------------------------

proc txBegin*(db: KvtDbRef): Result[KvtTxRef,KvtError] =
  ## Starts a new transaction.
  ##
  ## Example:
  ## ::
  ##   proc doSomething(db: KvtDbRef) =
  ##     let tx = db.txBegin
  ##     defer: tx.rollback()
  ##     ... continue using db ...
  ##     tx.commit()
  ##
  db.txFrameBegin()

proc rollback*(
    tx: KvtTxRef;                     # Top transaction on database
      ): Result[void,KvtError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##
  tx.txFrameRollback()

proc commit*(
    tx: KvtTxRef;                     # Top transaction on database
      ): Result[void,KvtError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  tx.txFrameCommit()

proc collapse*(
    tx: KvtTxRef;                     # Top transaction on database
    commit: bool;                     # Commit if `true`, otherwise roll back
      ): Result[void,KvtError] =
  ## Iterated application of `commit()` or `rollback()` performing the
  ## something similar to
  ## ::
  ##   while true:
  ##     discard tx.commit() # ditto for rollback()
  ##     if db.topTx.isErr: break
  ##     tx = db.topTx.value
  ##
  tx.txFrameCollapse commit

# ------------------------------------------------------------------------------
# Public functions: save database
# ------------------------------------------------------------------------------

proc persist*(
    db: KvtDbRef;                     # Database
      ): Result[void,KvtError] =
  ## Persistently store data onto backend database. If the system is running
  ## without a database backend, the function returns immediately with an
  ## error. The same happens if there is a pending transaction.
  ##
  ## The function merges all staged data from the top layer cache onto the
  ## backend stage area. After that, the top layer cache is cleared.
  ##
  ## Finally, the staged data are merged into the physical backend database
  ## and the staged data area is cleared. Wile performing this last step,
  ## the recovery journal is updated (if available.)
  ##
  db.txStow(persistent=true)

proc stow*(
    db: KvtDbRef;                     # Database
      ): Result[void,KvtError] =
  ## This function is similar to `persist()` stopping short of performing the
  ## final step storing on the persistent database. It fails if there is a
  ## pending transaction.
  ##
  ## The function merges all staged data from the top layer cache onto the
  ## backend stage area and leaves it there. This function can be seen as
  ## a sort of a bottom level transaction `commit()`.
  ##
  db.txStow(persistent=false)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
