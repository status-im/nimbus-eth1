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
  ./backend/accounts_ledger,
  ./base/[api_tracking, base_config, base_desc]

when LedgerEnableApiTracking:
  import
    std/times,
    chronicles
  logScope:
    topics = "ledger"
  const
    apiTxt = "API"

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator accounts*(ldg: LedgerRef): Account =
  ldg.beginTrackApi LdgAccountsIt
  for w in ldg.ac.accounts():
    yield w
  ldg.ifTrackApi: debug apiTxt, api, elapsed


iterator addresses*(ldg: LedgerRef): EthAddress =
  ldg.beginTrackApi LdgAdressesIt
  for w in ldg.ac.addresses():
    yield w
  ldg.ifTrackApi: debug apiTxt, api, elapsed


iterator cachedStorage*(ldg: LedgerRef, eAddr: EthAddress): (UInt256,UInt256) =
  ldg.beginTrackApi LdgCachedStorageIt
  for w in ldg.ac.cachedStorage(eAddr):
    yield w
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr)


iterator pairs*(ldg: LedgerRef): (EthAddress,Account) =
  ldg.beginTrackApi LdgPairsIt
  for w in ldg.ac.pairs():
    yield w
  ldg.ifTrackApi: debug apiTxt, api, elapsed


iterator storage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
      ): (UInt256,UInt256) =
  ldg.beginTrackApi LdgStorageIt
  for w in ldg.ac.storage(eAddr):
    yield w
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
