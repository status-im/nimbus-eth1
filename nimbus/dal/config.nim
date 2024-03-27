#   Nimbus
#   Copyright (c) 2021-2024 Status Research & Development GmbH
#   Licensed and distributed under either of
#     * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#     * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
#   at your option. This file may not be copied, modified, or distributed except according to those terms.

##  This module provides various configuration settings


const TraceLogs* {.booldefine.}: bool = false
  ## Whether to write trace-level logs to stdout.
  ## Overridable using -d:TraceLogs compile arg


const DisableCommitments* {.booldefine.}: bool = false
  ## Whether to not compute commitments. Used to speed up tests.
  ## Overridable using -d:DisableCommitments compile arg
