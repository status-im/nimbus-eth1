# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
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
##   LedgerRef   => AccountsCache, overloaded AccountsCache, etc.
##   LedgerSpRef => SavePoint, overloaded SavePoint etc
##
## In order to directly use `AccountsCache` it must be imported via
## `import db/ledger/accounts_cache`. In this case, there is no `LedgerRef`.
##
{.push raises: [].}

import
  eth/common,
  ./core_db,
  ./ledger/backend/[
    accounts_cache, accounts_cache_desc,
    accounts_ledger, accounts_ledger_desc],
  ./ledger/base_iterators

import
  ./ledger/base except LedgerApiTxt, beginTrackApi, bless, ifTrackApi

export
  AccountsCache,
  AccountsLedgerRef,
  LedgerType,
  base,
  base_iterators,
  init

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    ldgType: LedgerType;
    db: CoreDbRef;
    root: Hash256;
    pruneTrie: bool;
      ): LedgerRef =
  case ldgType:
  of LegacyAccountsCache:
    result = AccountsCache.init(db, root, pruneTrie)

  of LedgerCache:
    result = AccountsLedgerRef.init(db, root, pruneTrie)

  else:
    raiseAssert: "Missing ledger type label"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
