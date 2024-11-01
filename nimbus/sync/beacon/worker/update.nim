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
  ./headers_staged/staged_queue,
  "."/[blocks_unproc, db, headers_unproc, helpers]

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
  if target != 0 and target <= ctx.layout.head: # violates `H < T`
    trace info & ": update not applicable",
      H=ctx.layout.head.bnStr, T=target.bnStr
    return

  if ctx.layout.coupler != ctx.layout.dangling: # violates `C == D`
    trace info & ": update not applicable",
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
  ctx.dbStashHeaders(target, @[rlpHeader], info)

  # Save state
  ctx.dbStoreSyncStateLayout info

  # Update range
  doAssert ctx.headersUnprocTotal() == 0
  doAssert ctx.headersUnprocBorrowed() == 0
  doAssert ctx.headersStagedQueueIsEmpty()
  ctx.headersUnprocSet(ctx.layout.coupler+1, ctx.layout.dangling-1)

  trace info & ": updated sync state/new target", C=ctx.layout.coupler.bnStr,
    uTop=ctx.headersUnprocTop(),
    D=ctx.layout.dangling.bnStr, H=ctx.layout.head.bnStr, T=target.bnStr

  # Update, so it can be followed nicely
  ctx.updateMetrics()


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
    raiseAssert info & ": header chains C-D joining hashes do not match" &
      " L=" & ctx.chain.latestNumber().bnStr &
      " lHash=" & ctx.chain.latestHash.short &
      " C=" & ctx.layout.coupler.bnStr &
      " cHash=" & ctx.layout.couplerHash.short &
      " D=" & $ctx.layout.dangling.bnStr &
      " dParent=" & ctx.layout.danglingParent.short

  trace info & ": merging adjacent header chains", C=ctx.layout.coupler.bnStr,
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
  ctx.dbStoreSyncStateLayout info

  # Update, so it can be followed nicely
  ctx.updateMetrics()


proc updateTargetReached(ctx: BeaconCtxRef; info: static[string]) =
  # Open up layout for update
  ctx.layout.headLocked = false

  # Clean up target bucket and await a new target.
  ctx.target.reset
  ctx.hibernate = true

  let
    latest {.used.} = ctx.chain.latestNumber()
    head {.used.} = ctx.layout.head
  trace info & ": hibernating, awaiting new sync target",
    L=(if head == latest: "H" else: latest.bnStr), H=head.bnStr

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateSyncStateLayout*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update layout

  # Check whether the target has been reached. In that case, unlock the
  # consensus head `H` from the current layout so that it can be updated
  # in time.
  if ctx.layout.headLocked and                    # there is an active session
     ctx.layout.head <= ctx.chain.latestNumber(): # and target has been reached
    # Note that `latest` might exceed the `head`. This will happen when the
    # engine API got some request to execute and import subsequent blocks.
    ctx.updateTargetReached info

  # Check whether there is something to do regarding beacon node change
  if not ctx.layout.headLocked and         # there was an active import request
     ctx.target.changed and                # and there is a new target from CL
     ctx.target.final != 0:                # .. ditto
    ctx.target.changed = false
    ctx.updateTargetChange info

  # Check whether header downloading is done
  ctx.mergeAdjacentChains info


proc updateBlockRequests*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update block requests if there staged block queue is empty
  let latest = ctx.chain.latestNumber()
  if latest < ctx.layout.coupler:   # so half open interval `(L,C]` is not empty

    # One can fill/import/execute blocks by number from `(L,C]`
    if ctx.blk.topRequest < ctx.layout.coupler:
      # So there is some space
      trace info & ": updating block requests", L=latest.bnStr,
        topReq=ctx.blk.topRequest.bnStr, C=ctx.layout.coupler.bnStr

      ctx.blocksUnprocCommit(
        0, max(latest, ctx.blk.topRequest) + 1, ctx.layout.coupler)
      ctx.blk.topRequest = ctx.layout.coupler

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
