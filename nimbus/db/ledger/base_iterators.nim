# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/common,
  ../core_db,
  ./backend/[accounts_cache, accounts_cache_desc,
             accounts_ledger, accounts_ledger_desc],
  ./base/api_tracking,
  ./base

when LedgerEnableApiTracking:
  import
    std/times,
    chronicles
  const
    apiTxt = LedgerApiTxt

  func `$`(a: EthAddress): string {.used.} = a.toStr

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

# Note that there should be no closure iterators here, at least for the
# `storage()` iterator. With closures and the `accounts_cache.nim` driver
# as-is, all unit tests and no-hive work OK apart from `TracerTests` which
# fails at block 49018 due to mis-running of `storage()`.

iterator accounts*(ldg: LedgerRef): Account =
  ldg.beginTrackApi LdgAccountsIt
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.accountsIt():
      yield w
  of LedgerCache:
    for w in ldg.AccountsLedgerRef.accountsIt():
      yield w
  else:
    raiseAssert: "Unsupported ledger type: " & $ldg.ldgType
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed


iterator addresses*(ldg: LedgerRef): EthAddress =
  ldg.beginTrackApi LdgAdressesIt
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.addressesIt():
      yield w
  of LedgerCache:
    for w in ldg.AccountsLedgerRef.addressesIt():
      yield w
  else:
    raiseAssert: "Unsupported ledger type: " & $ldg.ldgType
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed


iterator cachedStorage*(ldg: LedgerRef, eAddr: EthAddress): (UInt256,UInt256) =
  ldg.beginTrackApi LdgCachedStorageIt
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.cachedStorageIt(eAddr):
      yield w
  of LedgerCache:
    for w in ldg.AccountsLedgerRef.cachedStorageIt(eAddr):
      yield w
  else:
    raiseAssert: "Unsupported ledger type: " & $ldg.ldgType
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr


iterator pairs*(ldg: LedgerRef): (EthAddress,Account) =
  ldg.beginTrackApi LdgPairsIt
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.pairsIt():
      yield w
  of LedgerCache:
    for w in ldg.AccountsLedgerRef.pairsIt():
      yield w
  else:
    raiseAssert: "Unsupported ledger type: " & $ldg.ldgType
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed


iterator storage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
      ): (UInt256,UInt256)
      {.gcsafe, raises: [CoreDbApiError].} =
  ldg.beginTrackApi LdgStorageIt
  case ldg.ldgType:
  of LegacyAccountsCache:
    for w in ldg.AccountsCache.storageIt(eAddr):
      yield w
  of LedgerCache:
    for w in ldg.AccountsLedgerRef.storageIt(eAddr):
      yield w
  else:
    raiseAssert: "Unsupported ledger type: " & $ldg.ldgType
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
