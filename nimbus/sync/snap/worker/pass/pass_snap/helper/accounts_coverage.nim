
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
  "../../../.."/range_desc,
  ../snap_pass_desc

# ------------------------------------------------------------------------------
# Public helpers: coverage
# ------------------------------------------------------------------------------

proc accountsCoverage*(ctx: SnapCtxRef): float =
  ## Returns the accounts coverage factor
  ctx.pool.pass.coveredAccounts.fullFactor + ctx.pool.pass.covAccTimesFull.float

proc accountsCoverage100PcRollOver*(ctx: SnapCtxRef) =
  ## Roll over `coveredAccounts` registry when it reaches 100%.
  let snap = ctx.pool.pass
  if snap.coveredAccounts.isFull:
    # All of accounts hashes are covered by completed range fetch processes
    # for all pivot environments. So reset covering and record full-ness level.
    snap.covAccTimesFull.inc
    snap.coveredAccounts.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
