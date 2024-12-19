# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Filter management
## ===========================
##

import
  std/tables,
  results,
  ./kvt_desc,
  ./kvt_desc/desc_backend

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deltaPersistentOk*(db: KvtDbRef): bool =
  ## Check whether txRef can be merged into the backend
  not db.backend.isNil


proc deltaPersistent*(
    db: KvtDbRef;                      # Database
      ): Result[void,KvtError] =
  ## Resolve (i.e. move) the backend filter into the physical backend database.
  ##
  ## This needs write permission on the backend DB for the argument `db`
  ## descriptor (see the function `aristo_desc.isCentre()`.) With the argument
  ## flag `reCentreOk` passed `true`, write permission will be temporarily
  ## acquired when needed.
  ##
  ## Other non-centre descriptors are updated so there is no visible database
  ## change for these descriptors.
  ##
  let be = db.backend
  if be.isNil:
    return err(FilBackendMissing)

  # Blind or missing filter
  if db.txRef.isNil:
    return ok()

  # Store structural single trie entries
  let writeBatch = ? be.putBegFn()
  for k,v in db.txRef.layer.sTab:
    be.putKvpFn(writeBatch, k, v)
  ? be.putEndFn writeBatch

  # Done with txRef, all saved to backend
  db.txRef.layer.sTab.clear()

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
