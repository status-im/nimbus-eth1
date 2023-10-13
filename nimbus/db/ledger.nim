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
  ./ledger/base,
  ./ledger/backend/[
    accounts_cache, accounts_cache_desc, accounts_ledger,  accounts_ledger_desc]
export
  AccountsCache,
  AccountsLedgerRef,
  base,
  init

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

# Note that there should be non-closure iterators here, at least for
# `storage()`. With closures and the `accounts_cache.nim` driver as-is, all
# unit tests and no-hive work OK apart from `TracerTests` which fails at block
# 49018 due to mis-running of `storage()`.

iterator accounts*(ldg: LedgerRef): Account =
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.accountsIt():
      yield w

  of LedgerCache:
    for w in ldg.AccountsLedgerRef.accountsIt():
      yield w

  else:
    raiseAssert: "Missing ledger type label"


iterator addresses*(ldg: LedgerRef): EthAddress =
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.addressesIt():
      yield w

  of LedgerCache:
    for w in ldg.AccountsLedgerRef.addressesIt():
      yield w

  else:
    raiseAssert: "Missing ledger type label"
        

iterator cachedStorage*(ldg: LedgerRef, eAddr: EthAddress): (UInt256,UInt256) =
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.cachedStorageIt(eAddr):
      yield w

  of LedgerCache:
    for w in ldg.AccountsLedgerRef.cachedStorageIt(eAddr):
      yield w

  else:
    raiseAssert: "Missing ledger type label"


iterator pairs*(ldg: LedgerRef): (EthAddress,Account) =
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.pairsIt():
      yield w

  of LedgerCache:
    for w in ldg.AccountsLedgerRef.pairsIt():
      yield w

  else:
    raiseAssert: "Missing ledger type label"


iterator storage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
      ): (UInt256,UInt256)
      {.gcsafe, raises: [CoreDbApiError].} =
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.storageIt(eAddr):
      yield w

  of LedgerCache:
    for w in ldg.AccountsLedgerRef.storageIt(eAddr):
      yield w

  else:
    raiseAssert: "Missing ledger type label"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
