# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronos, metrics],
  ../worker_desc

declareGauge nec_snap_eta_secs, "" &
  "Estimated seconds until current download or DB import terminates"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateEta*(ctx: SnapCtxRef, y: float) =
  ctx.pool.etaSpline.apply y
  ctx.pool.etaSpline.eta.isErrOr:
    metrics.set(nec_snap_eta_secs, value.seconds)
    return
  if ctx.pool.etaSpline.len < 2:
    metrics.set(nec_snap_eta_secs, -1)

proc resetEta*(ctx: SnapCtxRef) =
  metrics.set(nec_snap_eta_secs, 0)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
