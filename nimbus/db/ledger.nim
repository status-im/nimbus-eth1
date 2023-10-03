# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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
##   LedgerRef   => AccountsCache, WrappedAccountsCache, etc.
##   LedgerSpRef => SavePoint, WrappedSavePoint, etc
##
## Note that for the legacy `AccountsCache`, the field `ldgType` has
## value `LedgerType(0)`. It is different for the wrapped objects, e.g.
## `WrappedAccountsCache`.
##
## In order to directly use `AccountsCache` it must be imported via
## `import db/ledger/accounts_cache`.
##
{.push raises: [].}

# Unified ledger, includes `accounts_cache` as legacy ledger
import
  ./ledger/base,
  ./ledger/backend/[accounts_cache, cached_ledger]
export
  base, accounts_cache, cached_ledger

# End
