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
  ../../aristo/aristo_profile,
  ../accounts_ledger

export
  accounts_ledger

type
  LedgerProfListRef* = AristoDbProfListRef
    ## Borrowed from `aristo_profile`, only used in profiling mode

  LedgerProfData* = AristoDbProfData
    ## Borrowed from `aristo_profile`, only used in profiling mode

  LedgerSpRef* = LedgerSavePoint
    ## Object for check point or save point

  LedgerRef* = ref object of RootRef
    ## Root object with closures
    trackApi*: bool             ## For debugging
    profTab*: LedgerProfListRef ## Profiling data (if any)
    ac*: AccountsLedgerRef

# End
