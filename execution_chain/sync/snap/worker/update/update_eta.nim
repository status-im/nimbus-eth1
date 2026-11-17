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
  ../../../../utils/simple_eta,
  ../worker_desc

declareGauge nec_snap_accounts_eta_secs, "" &
  "Estimated seconds until current accounts download terminates"

declareGauge nec_snap_dbimport_eta_secs, "" &
  "Estimated seconds until current Core DB import terminates"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template etaInit(spline: EtaSpline, gauge: untyped): untyped =
  spline.init()
  metrics.set(gauge, 0)

template etaUpdate(spline: EtaSpline, gauge: untyped, y: float): untyped =
  spline.apply y
  spline.eta.isErrOr:
    metrics.set(gauge, value.seconds)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc accEtaInit*(ctx: SnapCtxRef) =
  ctx.pool.etaAccounts.etaInit nec_snap_accounts_eta_secs

proc accEtaUpdate*(ctx: SnapCtxRef, y: float) =
  ctx.pool.etaAccounts.etaUpdate(nec_snap_accounts_eta_secs, y)

proc dbImportEtaInit*(ctx: SnapCtxRef) =
  ctx.pool.etaDbImport.etaInit nec_snap_dbimport_eta_secs

proc dbImportEtaUpdate*(ctx: SnapCtxRef, y: float) =
  ctx.pool.etaDbImport.etaUpdate(nec_snap_dbimport_eta_secs, y)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
