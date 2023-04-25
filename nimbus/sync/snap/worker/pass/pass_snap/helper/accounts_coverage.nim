
# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  stew/interval_set,
  "../../../.."/[range_desc, worker_desc]

# ------------------------------------------------------------------------------
# Public helpers: coverage
# ------------------------------------------------------------------------------

proc accountsCoverage*(ctx: SnapCtxRef): float =
  ## Returns the accounts coverage factor
  ctx.pool.coveredAccounts.fullFactor + ctx.pool.covAccTimesFull.float

proc accountsCoverage100PcRollOver*(ctx: SnapCtxRef) =
  ## Roll over `coveredAccounts` registry when it reaches 100%.
  if ctx.pool.coveredAccounts.isFull:
    # All of accounts hashes are covered by completed range fetch processes
    # for all pivot environments. So reset covering and record full-ness level.
    ctx.pool.covAccTimesFull.inc
    ctx.pool.coveredAccounts.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
