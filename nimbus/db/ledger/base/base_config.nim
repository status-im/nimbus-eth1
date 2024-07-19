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

import ../../core_db/base/base_config

# Configuration section
const
  EnableApiTracking = false
    ## When enabled, API functions are logged. Tracking is enabled by setting
    ## the `trackApi` flag to `true`. This setting is typically inherited from
    ## the `CoreDb` descriptor flag `trackLedgerApi` (which is only available
    ## if the flag `CoreDbEnableApiTracking` is set `true`.

  EnableApiProfiling = false
    ## Enable API functions profiling. This setting is only effective if the
    ## flag `CoreDbEnableApiJumpTable` is set `true`.

# Exportable constants (leave alone this section)
const
  LedgerEnableApiTracking* = EnableApiTracking and CoreDbEnableApiTracking
  LedgerEnableApiProfiling* = EnableApiProfiling and CoreDbEnableApiJumpTable

# End
