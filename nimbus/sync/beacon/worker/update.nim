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
  pkg/stew/sorted_set,
  ../worker_desc,
  ./update/metrics,
  "."/[blocks_unproc, db, headers_staged, headers_unproc]

logScope:
  topics = "beacon update"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updateTargetChange(ctx: BeaconCtxRef; info: static[string]) =
  ##
  ## Layout (see (3) in README):
  ## ::
  ##     0             C==D==H                  T
  ##     o----------------o---------------------o---->
  ##     | <-- linked --> |
  ##
  ## or
  ## ::
  ##    0==T           C==D==H
  ##     o----------------o-------------------------->
  ##     | <-- linked --> |
  ##
  ## with `T == target.consHead.number` or `T == 0`
  ##
  ## to be updated to
  ## ::
  ##     0               C==D                 D'==H'
  ##     o----------------o---------------------o---->
  ##     | <-- linked --> | <-- unprocessed --> |
  ##
  var target = ctx.target.consHead.number

  # Need: `H < T` and `C == D`
  if target != 0 and target <= ctx.layout.head:      # violates `H < T`
    trace info & ": not applicable", H=ctx.layout.head.bnStr, T=target.bnStr
    return

  if ctx.layout.coupler != ctx.layout.dangling: # violates `C == D`
    trace info & ": not applicable",
      C=ctx.layout.coupler.bnStr, D=ctx.layout.dangling.bnStr
    return

  # Check consistency: `C == D <= H` for maximal `C` => `D == H`
  doAssert ctx.layout.dangling == ctx.layout.head

  let rlpHeader = rlp.encode(ctx.target.consHead)

  ctx.sst.layout = SyncStateLayout(
    coupler:        ctx.layout.coupler,
    couplerHash:    ctx.layout.couplerHash,
    dangling:       target,
    danglingParent: ctx.target.consHead.parentHash,
    final:          ctx.target.final,
    finalHash:      ctx.target.finalHash,
    head:           target,
    headHash:       rlpHeader.keccak256,
    headLocked:     true)

  # Save this header on the database so it needs not be fetched again from
  # somewhere else.
  ctx.dbStashHeaders(target, @[rlpHeader])

  # Save state
  ctx.dbStoreSyncStateLayout()

  # Update range
  doAssert ctx.headersUnprocTotal() == 0
  doAssert ctx.headersUnprocBorrowed() == 0
  doAssert ctx.headersStagedQueueIsEmpty()
  ctx.headersUnprocSet(ctx.layout.coupler+1, ctx.layout.dangling-1)

  trace info & ": updated", C=ctx.layout.coupler.bnStr,
    uTop=ctx.headersUnprocTop(),
    D=ctx.layout.dangling.bnStr, H=ctx.layout.head.bnStr, T=target.bnStr


proc mergeAdjacentChains(ctx: BeaconCtxRef; info: static[string]) =
  ## Merge if `C+1` == `D`
  ##
  if ctx.layout.coupler+1 < ctx.layout.dangling or # gap btw. `C` & `D`
     ctx.layout.coupler == ctx.layout.dangling:    # merged already
    return

  # No overlap allowed!
  doAssert ctx.layout.coupler+1 == ctx.layout.dangling

  # Verify adjacent chains
  if ctx.layout.couplerHash != ctx.layout.danglingParent:
    # FIXME: Oops -- any better idea than to defect?
    raiseAssert info & ": hashes do not match" &
      " C=" & ctx.layout.coupler.bnStr & " D=" & $ctx.layout.dangling.bnStr

  trace info & ": merging", C=ctx.layout.coupler.bnStr,
    D=ctx.layout.dangling.bnStr

  # Merge adjacent linked chains
  ctx.sst.layout = SyncStateLayout(
    coupler:        ctx.layout.head,               # `C`
    couplerHash:    ctx.layout.headHash,
    dangling:       ctx.layout.head,               # `D`
    danglingParent: ctx.dbPeekParentHash(ctx.layout.head).expect "Hash32",
    final:          ctx.layout.final,              # `F`
    finalHash:      ctx.layout.finalHash,
    head:           ctx.layout.head,               # `H`
    headHash:       ctx.layout.headHash,
    headLocked:     ctx.layout.headLocked)

  # Save state
  ctx.dbStoreSyncStateLayout()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateSyncStateLayout*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update layout

  # Check whether the target has been reached. In that case, unlock the
  # consensus head `H` from the current layout so that it can be updated
  # in time.
  if ctx.layout.headLocked:
    # So we have a session
    let base = ctx.dbStateBlockNumber()
    if ctx.layout.head <= base:
      doAssert ctx.layout.head == base
      ctx.layout.headLocked = false

  # Check whether there is something to do regarding beacon node change
  if not ctx.layout.headLocked and ctx.target.changed and ctx.target.final != 0:
    ctx.target.changed = false
    ctx.updateTargetChange info

  # Check whether header downloading is done
  ctx.mergeAdjacentChains info


proc updateBlockRequests*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update block requests if there staged block queue is empty
  let base = ctx.dbStateBlockNumber()
  if base < ctx.layout.coupler:   # so half open interval `(B,C]` is not empty

    # One can fill/import/execute blocks by number from `(B,C]`
    if ctx.blk.topRequest < ctx.layout.coupler:
      # So there is some space
      trace info & ": updating", B=base.bnStr, topReq=ctx.blk.topRequest.bnStr,
        C=ctx.layout.coupler.bnStr

      ctx.blocksUnprocCommit(
        0, max(base, ctx.blk.topRequest) + 1, ctx.layout.coupler)
      ctx.blk.topRequest = ctx.layout.coupler


proc updateMetrics*(ctx: BeaconCtxRef) =
  let now = Moment.now()
  if ctx.pool.nextUpdate < now:
    ctx.updateMetricsImpl()
    ctx.pool.nextUpdate = now + metricsUpdateInterval

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
