# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Read only source, import `state_db/read_write` for full functionality.
##
## Note that the writable mode is only partially supported by the `Aristo`
## backend of `CoreDb` (read-only mode is fully supported.)

import
  state_db/[base, read_only]

export
  AccountStateDB,
  ReadOnlyStateDB,
  accountExists,
  getAccount,
  getBalance,
  getCode,
  getCodeHash,
  getNonce,
  getStorage,
  getStorageRoot,
  getTrie,
  contractCollision,
  isDeadAccount,
  isEmptyAccount,
  newAccountStateDB,
  rootHash,
  getAccountProof,
  getStorageProof

# End
