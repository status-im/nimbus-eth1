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
  ./kvt_tx/[tx_frame, tx_stow],
  ./kvt_init/memory_only,
  ./kvt_desc

export tx_frame


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(tx: KvtTxRef; T: type[KvtDbRef]): T =
  ## Getter, retrieves the parent database descriptor from argument `tx`
  tx.db

func toKvtDbRef*(tx: KvtTxRef): KvtDbRef =
  ## Same as `.to(KvtDbRef)`
  tx.db

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
  # Register for saving if piggybacked on remote database
  if db.backend.kind == BackendRdbTriggered:
    ? db.txPersistOk()
    ? db.backend.setWrReqFn db
    return err(TxPersistDelayed)

  db.txPersist()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
