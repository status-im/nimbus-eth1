# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  ../../core_db,
  "."/[api_tracking, base_config, base_desc]

# ------------------------------------------------------------------------------
# Public constructor helper
# ------------------------------------------------------------------------------

when LedgerEnableApiProfiling:
  proc ldgProfData*(db: CoreDbRef): LedgerProfListRef =
    ## Return profiling data table (only available in profiling mode). If
    ## available (i.e. non-nil), result data can be organised by the functions
    ## available with `aristo_profile`.
    ##
    ## Note that profiling these data have accumulated over several ledger
    ## sessions running on the same `CoreDb` instance.
    ##
    if db.ledgerHook.isNil:
      db.ledgerHook = LedgerProfListRef.init()
    cast[LedgerProfListRef](db.ledgerHook)

proc bless*(ldg: LedgerRef; db: CoreDbRef): LedgerRef =
  when LedgerEnableApiTracking:
    ldg.trackApi = db.trackLedgerApi
  when LedgerEnableApiProfiling:
    ldg.profTab = db.ldgProfData()
  ldg

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
