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
  pkg/[eth/common, stew/interval_set],
  ../worker_desc,
  ./blocks_unproc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc blocksReconcileUnproc*(ctx: BeaconCtxRef) =
  ## Re-examine the live `FC` head and fast-forward the session bookkeeping to
  ## match it. A concurrent importer (e.g. `el_sync` feeding the EL via the
  ## engine API) can advance the `FC latest` past where we are fetching.
  ##
  ## Bumping `topNum` to the current `FC` head and dropping the now-redundant
  ## `unprocessed` numbers makes the next fetch start at `latest + 1`, whose
  ## parent is the live `FC` tip.
  ##
  ## This is only safe when the `FC` head is on the very lineage we are syncing.
  ## The header cache holds the target (CL fork-choice) lineage; we fast-forward
  ## only if its hash at `fcLatest` equals the `FC` head hash. During a reorg
  ## the `FC` head can sit on a soon-to-be-abandoned branch whose blocks at
  ## these numbers differ from the new canonical ones - skipping by number
  ## would then strand the new branch. In that case we leave `topNum` alone and
  ## let the in-order import hand each block to the `FC`, which classifies it
  ## correctly.
  let fcLatest = ctx.chain.latestNumber

  # Defer the fork decision to the target lineage rather than trusting a raw
  # block number.
  let lineageHash = ctx.hdrCache.getHash(fcLatest).valueOr:
    return                                 # `fcLatest` outside the target chain
  if lineageHash != ctx.chain.latestHash:
    return                                 # `FC` head is on another branch

  let top = min(fcLatest, ctx.subState.headNum)
  if ctx.subState.topNum < top:
    ctx.subState.topNum = top
    discard ctx.blk.unprocessed.reduce(0u64, fcLatest)
    ctx.blocksUnprocMetricsUpdate()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
