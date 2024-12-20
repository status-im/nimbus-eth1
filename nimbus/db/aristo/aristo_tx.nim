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

export tx_frame

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(tx: AristoTxRef; T: type[AristoDbRef]): T =
  ## Getter, retrieves the parent database descriptor from argument `tx`
  tx.db

# ------------------------------------------------------------------------------
# Public functions: Transaction frame
# ------------------------------------------------------------------------------

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
  db.txPersist(nxtSid)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
