# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Unifies different ledger management APIs. All ledger objects are
## derived from the base objects
## ::
##   LedgerSpRef => SavePoint, overloaded SavePoint etc
##
{.push raises: [].}

import
  eth/common,
  ./core_db,
  ./ledger/backend/accounts_ledger,
  ./ledger/base/[base_config, base_desc, base_helpers],
  ./ledger/[base, base_iterators]

export AccountsLedgerRef, base, base_config, base_iterators

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(_: type LedgerRef, db: CoreDbRef, root: Hash256): LedgerRef =
  LedgerRef(ac: AccountsLedgerRef.init(db, root)).bless(db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
