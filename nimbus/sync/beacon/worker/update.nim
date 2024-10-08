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

proc updateTargetChange(ctx: BeaconCtxRef; info: static[string]): bool =
  ##
  ## Layout (see (3) in README):
  ## ::
  ##     0             C==D==E                  F
  ##     o----------------o---------------------o---->
  ##     | <-- linked --> |
  ##
  ## or
  ## ::
  ##    0==F           C==D==E
  ##     o----------------o-------------------------->
  ##     | <-- linked --> |
  ##
  ## with `F == final.header.number` or `F == 0`
  ##
  ## to be updated to
  ## ::
  ##     0               C==D                 D'==E'
  ##     o----------------o---------------------o---->
  ##     | <-- linked --> | <-- unprocessed --> |
  ##
  var target = ctx.lhc.target.header.number

  # Need: `E < F` and `C == D`
  if target != 0 and target <= ctx.layout.endBn:      # violates `E < F`
    trace info & ": not applicable", E=ctx.layout.endBn.bnStr, F=target.bnStr
    return false

  if ctx.layout.coupler != ctx.layout.dangling: # violates `C == D`
    trace info & ": not applicable",
      C=ctx.layout.coupler.bnStr, D=ctx.layout.dangling.bnStr
    return false

  # Check consistency: `C == D <= E` for maximal `C` => `D == E`
  doAssert ctx.layout.dangling == ctx.layout.endBn

  let rlpHeader = rlp.encode(ctx.lhc.target.header)

  ctx.lhc.layout = LinkedHChainsLayout(
    coupler:        ctx.layout.coupler,
    couplerHash:    ctx.layout.couplerHash,
    dangling:       target,
    danglingParent: ctx.lhc.target.header.parentHash,
    endBn:          target,
    endHash:        rlpHeader.keccak256)

  # Save this header on the database so it needs not be fetched again from
  # somewhere else.
  ctx.dbStashHeaders(target, @[rlpHeader])

  # Save state
  discard ctx.dbStoreLinkedHChainsLayout()

  # Update range
  doAssert ctx.headersUnprocTotal() == 0
  doAssert ctx.headersUnprocBorrowed() == 0
  doAssert ctx.headersStagedQueueIsEmpty()
  ctx.headersUnprocSet(ctx.layout.coupler+1, ctx.layout.dangling-1)

  trace info & ": updated", C=ctx.layout.coupler.bnStr,
    D=ctx.layout.dangling.bnStr, E=ctx.layout.endBn.bnStr, F=target.bnStr
  true


proc mergeAdjacentChains(ctx: BeaconCtxRef; info: static[string]): bool =
  if ctx.lhc.layout.coupler+1 < ctx.lhc.layout.dangling or # gap btw. `C` & `D`
     ctx.lhc.layout.coupler == ctx.lhc.layout.dangling:    # merged already
    return false

  # No overlap allowed!
  doAssert ctx.lhc.layout.coupler+1 == ctx.lhc.layout.dangling

  # Verify adjacent chains
  if ctx.lhc.layout.couplerHash != ctx.lhc.layout.danglingParent:
    # FIXME: Oops -- any better idea than to defect?
    raiseAssert info & ": hashes do not match" &
      " C=" & ctx.lhc.layout.coupler.bnStr &
      " D=" & $ctx.lhc.layout.dangling.bnStr

  trace info & ": merging", C=ctx.lhc.layout.coupler.bnStr,
    D=ctx.lhc.layout.dangling.bnStr

  # Merge adjacent linked chains
  ctx.lhc.layout = LinkedHChainsLayout(
    coupler:        ctx.layout.endBn,               # `C`
    couplerHash:    ctx.layout.endHash,
    dangling:       ctx.layout.endBn,               # `D`
    danglingParent: ctx.dbPeekParentHash(ctx.layout.endBn).expect "Hash32",
    endBn:          ctx.layout.endBn,               # `E`
    endHash:        ctx.layout.endHash)

  # Save state
  discard ctx.dbStoreLinkedHChainsLayout()

  true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateLinkedHChainsLayout*(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Update layout

  # Check whether there is something to do regarding beacon node change
  if ctx.lhc.target.changed:
    ctx.lhc.target.changed = false
    result = ctx.updateTargetChange info

  # Check whether header downloading is done
  if ctx.mergeAdjacentChains info:
    result = true


proc updateBlockRequests*(ctx: BeaconCtxRef; info: static[string]): bool =
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
      return true

  false


proc updateMetrics*(ctx: BeaconCtxRef) =
  let now = Moment.now()
  if ctx.pool.nextUpdate < now:
    ctx.updateMetricsImpl()
    ctx.pool.nextUpdate = now + metricsUpdateInterval

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
