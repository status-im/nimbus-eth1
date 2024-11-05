# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  pkg/eth/[common, rlp],
  pkg/stew/[byteutils, sorted_set],
  ../../../core/chain,
  ../worker_desc,
  ./update/metrics,
  ./blocks_staged/staged_queue,
  ./headers_staged/staged_queue,
  "."/[blocks_unproc, db, headers_unproc, helpers]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc resetSyncStateIdle(ctx: BeaconCtxRef; info: static[string]) =
  ## Clean up target bucket and await a new target.
  ##
  ctx.sst.reset # => target.reset, layout.reset
  ctx.headersUnprocReset()
  ctx.blocksUnprocReset()
  ctx.headersStagedQueueReset()
  ctx.blocksStagedQueueReset()

  ctx.hibernate = true

  let
    latest {.used.} = ctx.chain.latestNumber()
    head  {.used.} = ctx.layout.head
  trace info & ": hibernating, awaiting new sync target",
    L=(if head == latest: "H" else: latest.bnStr), H=head.bnStr

  # Update, so it can be followed nicely
  ctx.updateMetrics()


proc updateSyncHead(ctx: BeaconCtxRef; info: static[string]) =
  ## Layout (see clause *(8)* in `README.md`):
  ## ::
  ##   0               H    L
  ##   o---------------o----o
  ##   | <--- imported ---> |
  ##
  ## where `H << L` with `L` is the `latest` (aka cursor) parameter from
  ## `FC` the logic will be updated to (see clause *(9)* in `README.md`):
  ## ::
  ##   0            B
  ##   o------------o-------o
  ##   | <--- imported ---> |                             D
  ##                  C                                   H
  ##                  o-----------------------------------o
  ##                  | <--------- unprocessed ---------> |
  ##
  ## where *B* is the **base** entity of the `FC` module and `C` is sort of
  ## a placehoder with with block number one greater than B. The parameter
  ## `H` is set to the new sync head target `T`.
  ##
  var
    b = ctx.chain.baseNumber()
    h = ctx.layout.head
    l = ctx.chain.latestNumber()
    t = ctx.target.consHead.number

  # Need: `H <= L < T`
  if l < h or t <= l:
    trace info & ": update not applicable", B=b.bnStr,
      H=h.bnStr, L=l.bnStr, T=t.bnStr
    return

  ctx.sst.layout = SyncStateLayout(
    coupler:        b + 1,
    dangling:       t,
    final:          ctx.target.final,
    finalHash:      ctx.target.finalHash,
    head:           t,
    headLocked:     true)

  # Save this header on the database so it needs not be fetched again from
  # somewhere else.
  ctx.dbStashHeaders(t, @[rlp.encode(ctx.target.consHead)], info)

  # Save state
  ctx.dbStoreSyncStateLayout info

  # Update range
  doAssert ctx.headersUnprocTotal() == 0
  doAssert ctx.headersUnprocBorrowed() == 0
  doAssert ctx.headersStagedQueueIsEmpty()
  ctx.headersUnprocSet(ctx.layout.coupler, ctx.layout.dangling-1)

  trace info & ": updated sync new target", C=ctx.layout.coupler.bnStr,
    uTop=ctx.headersUnprocTop(), D="H", H="T", T=t.bnStr

  # Update, so it can be followed nicely
  ctx.updateMetrics()


proc mergeAdjacentChains(ctx: BeaconCtxRef; info: static[string]) =
  ## Layout (see clause *(8)* in `README.md`):
  ## ::
  ##   0               Z    L
  ##   o---------------o----o
  ##   | <--- imported ---> |
  ##                C  Z                                  H
  ##                o--o----------------------------------o
  ##                | <-------------- linked -----------> |
  ##
  ## where `C << D` (typically `C==D`.)
  ##
  ## If there is such a `Z`, then update the sync state to (see chause *(11)*
  ## in `README.md`):
  ## ::
  ##   0               Z
  ##   o---------------o----o
  ##   | <--- imported ---> |
  ##                     D'
  ##                     C'                               H
  ##                     o--------------------------------o
  ##                     | <-- blocks to be completed --> |
  ##
  ## where `C'` is the header from `(Z,H]` with *Z* as parent.
  ##
  ## Otherwise, if *Z* does not exists then reset to idle state.
  ##
  let
    l = ctx.chain.latestNumber()
    d = ctx.layout.dangling

  # So `D <= L` is necessary for `D`, otherwise there was some big internal
  # change and all we can do is to reset the syncer. Also if `L < H` does
  # not hold then the sync is done, already.
  #
  if d <= l and l < ctx.layout.head:
    #
    # Try to find a parent in the `FC` data domain. The loop starts by checking
    # for `ctx.chain.latestHash() == dbPeekParentHash(dangling)` which covers
    # most of all cases.
    #
    for bn in (l+1).countdown(d):
      # The syncer cache holds headers for `[D,H]`
      let
        parent = ctx.dbPeekParentHash(bn).expect "Hash32"
        fcHdr = ctx.chain.headerByHash(parent).valueOr:
          continue
        fcNum = fcHdr.number

      ctx.layout.coupler = fcNum # `C'`
      ctx.layout.dangling = fcNum # `D'`

      trace info & ": merged header chain", D=d.bnStr,
        C=(if fcNum == l: "L" else: fcNum.bnStr), L=l.bnStr,
        H=ctx.layout.head.bnStr

      # Save state
      ctx.dbStoreSyncStateLayout info

      # Update, so it can be followed nicely
      ctx.updateMetrics()
      return

  ctx.resetSyncStateIdle info

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateSyncStateLayout*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update layout

  # Check whether the the current sync cycle is done. This is reached when the
  # `latest` parameter form the `FC` logic reaches the sync head `H` (see
  # clause *(8)* in `README.md`)
  if ctx.layout.headLocked and                    # there is an active session
     ctx.layout.head <= ctx.chain.latestNumber(): # and target has been reached
    ctx.resetSyncStateIdle info

  # Check whether there is something to do regarding beacon node change
  if not ctx.layout.headLocked and         # there was no active import request
     ctx.target.changed and                # and there is a new target from CL
     ctx.target.final != 0:                # .. ditto
    ctx.target.changed = false             # consume target
    ctx.updateSyncHead info

  # Check whether header downloading is done and the header intervals can
  # be merged (logically) with the canonical block chain.
  if ctx.layout.coupler + 1 == ctx.layout.dangling:
    ctx.mergeAdjacentChains info


proc updateBlockRequests*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update block requests if the staged block queue is empty and should be
  ## filled. The sync state looks like
  ## ::
  ##   0                    L
  ##   o--------------------o
  ##   | <--- imported ---> |
  ##                     C
  ##                     D                                H
  ##                     o--------------------------------o
  ##                     | <-- blocks to be completed --> |
  ##
  ## where `L` is  the `latest` (aka cursor) parameter from the `FC` logic
  ##
  if ctx.blocksUnprocIsEmpty() and ctx.blocksUnprocBorrowed() == 0:

    if ctx.layout.coupler == ctx.layout.dangling and   # `C == D`
       ctx.layout.dangling < ctx.layout.head:          # `D < H`

      let l = ctx.chain.latestNumber()
      if ctx.layout.coupler <= l and                   # `C <= L`
         l < ctx.layout.head:                          # `L <= H`

        # Update blocks `[C,H]`
        ctx.blocksUnprocCommit(0, ctx.layout.coupler, ctx.layout.head)
        ctx.blk.topRequest = ctx.layout.head

        trace info & ": updating block requests", L=l.bnStr,
          topReq=ctx.blk.topRequest.bnStr, C=ctx.layout.coupler.bnStr,
          H=ctx.layout.head.bnStr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
