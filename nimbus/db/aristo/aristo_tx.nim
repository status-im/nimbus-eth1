# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Transaction interface
## ==================================
##
{.push raises: [].}

import
  results,
  ./aristo_tx/[tx_frame, tx_stow],
  ./aristo_desc

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func txTop*(db: AristoDbRef): Result[AristoTxRef,AristoError] =
  ## Getter, returns top level transaction if there is any.
  db.txFrameTop()

func isTop*(tx: AristoTxRef): bool =
  ## Getter, returns `true` if the argument `tx` referes to the current top
  ## level transaction.
  tx.txFrameIsTop()

func txLevel*(tx: AristoTxRef): int =
  ## Getter, positive nesting level of transaction argument `tx`
  tx.txFrameLevel()

func level*(db: AristoDbRef): int =
  ## Getter, non-negative nesting level (i.e. number of pending transactions)
  db.txFrameLevel()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(tx: AristoTxRef; T: type[AristoDbRef]): T =
  ## Getter, retrieves the parent database descriptor from argument `tx`
  tx.db

# ------------------------------------------------------------------------------
# Public functions: Transaction frame
# ------------------------------------------------------------------------------

proc txBegin*(db: AristoDbRef): Result[AristoTxRef,AristoError] =
  ## Starts a new transaction.
  ##
  ## Example:
  ## ::
  ##   proc doSomething(db: AristoDbRef) =
  ##     let tx = db.begin
  ##     defer: tx.rollback()
  ##     ... continue using db ...
  ##     tx.commit()
  ##
  db.txFrameBegin()

proc rollback*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##
  tx.txFrameRollback()

proc commit*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  tx.txFrameCommit()

proc collapse*(
    tx: AristoTxRef;                  # Top transaction on database
    commit: bool;                     # Commit if `true`, otherwise roll back
      ): Result[void,AristoError] =
  ## Iterated application of `commit()` or `rollback()` performing the
  ## something similar to
  ## ::
  ##   while true:
  ##     discard tx.commit() # ditto for rollback()
  ##     if db.txTop.isErr: break
  ##     tx = db.txTop.value
  ##
  tx.txFrameCollapse commit

# ------------------------------------------------------------------------------
# Public functions: save to database
# ------------------------------------------------------------------------------

proc persist*(
    db: AristoDbRef;                  # Database
    nxtSid = 0u64;                    # Next state ID (aka block number)
      ): Result[void,AristoError] =
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
  ## If the argument `nxtSid` is passed non-zero, it will be the ID for the
  ## next recovery journal record. If non-zero, this ID must be greater than
  ## all previous IDs (e.g. block number when stowing after block execution.)
  ##
  db.txStow(nxtSid, persistent=true)

proc stow*(
    db: AristoDbRef;                  # Database
      ): Result[void,AristoError] =
  ## This function is similar to `persist()` stopping short of performing the
  ## final step storing on the persistent database. It fails if there is a
  ## pending transaction.
  ##
  ## The function merges all staged data from the top layer cache onto the
  ## backend stage area and leaves it there. This function can be seen as
  ## a sort of a bottom level transaction `commit()`.
  ##
  db.txStow(nxtSid=0u64, persistent=false)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
