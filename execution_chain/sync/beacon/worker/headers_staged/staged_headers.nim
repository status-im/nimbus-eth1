# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronicles, chronos],
  pkg/eth/common,
  pkg/stew/interval_set,
  ../../worker_desc,
  ./headers_fetch

# ------------------------------------------------------------------------------
# Public helper functions
# ------------------------------------------------------------------------------

proc headersUpdateBuddyErrorState*(buddy: BeaconBuddyRef) =
  ## Helper/wrapper
  if ((0 < buddy.nHdrRespErrors or
       0 < buddy.nHdrProcErrors) and buddy.ctrl.stopped) or
     fetchHeadersReqErrThresholdCount < buddy.nHdrRespErrors or
     fetchHeadersProcessErrThresholdCount < buddy.nHdrProcErrors:

    # Make sure that this peer does not immediately reconnect
    buddy.ctrl.zombie = true

proc headersUpdateBuddyProcError*(buddy: BeaconBuddyRef) =
  buddy.incHdrProcErrors()
  buddy.headersUpdateBuddyErrorState()

# -----------------

proc headersStashOnDisk*(
  buddy: BeaconBuddyRef;
  revHdrs: seq[Header];
  info: static[string];
    ): bool =
  ## Convenience wrapper, makes it easy to produce comparable messages
  ## whenever it is called similar to `blocksImport()`.
  let
    ctx = buddy.ctx
    d9 = ctx.hdrCache.antecedent.number # for logging
    rc = ctx.hdrCache.put(revHdrs)

  if rc.isErr:
    buddy.headersUpdateBuddyProcError()
    debug info & ": header stash error", peer=buddy.peer, iv=revHdrs.bnStr,
      syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors, error=rc.error

  let d0 = ctx.hdrCache.antecedent.number
  info "Cached headers", iv=(if d0 < d9: (d0,d9-1).bnStr else: "n/a"),
    nHeaders=(d9 - d0),
    nSkipped=(if rc.isErr: 0u64
              elif revHdrs[^1].number <= d0: (d0 - revHdrs[^1].number)
              else: revHdrs.len.uint64),
    base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
    target=ctx.subState.head.bnStr, targetHash=ctx.subState.headHash.short

  rc.isOk

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
