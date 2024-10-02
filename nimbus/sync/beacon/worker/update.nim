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
  "."/[blocks_unproc, db, headers_staged, headers_unproc, helpers]

logScope:
  topics = "beacon update"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updateBeaconChange(ctx: BeaconCtxRef): bool =
  ##
  ## Layout (see (3) in README):
  ## ::
  ##     G             C==L==F                  Z
  ##     o----------------o---------------------o---->
  ##     | <-- linked --> |
  ##
  ## or
  ## ::
  ##    G==Z           C==L==F
  ##     o----------------o-------------------------->
  ##     | <-- linked --> |
  ##
  ## with `Z == beacon.header.number` or `Z == 0`
  ##
  ## to be updated to
  ## ::
  ##     G               C==L                 L'==F'
  ##     o----------------o---------------------o---->
  ##     | <-- linked --> | <-- unprocessed --> |
  ##
  const info = "updateBeaconChange"

  var z = ctx.lhc.beacon.header.number

  # Need: `F < Z` and `C == L`
  if z != 0 and z <= ctx.layout.final:       # violates `F < Z`
    trace info & ": not applicable", Z=z.bnStr, F=ctx.layout.final.bnStr
    return false

  if ctx.layout.coupler != ctx.layout.least: # violates `C == L`
    trace info & ": not applicable",
      C=ctx.layout.coupler.bnStr, L=ctx.layout.least.bnStr
    return false

  # Check consistency: `C == L <= F` for maximal `C` => `L == F`
  doAssert ctx.layout.least == ctx.layout.final

  let rlpHeader = rlp.encode(ctx.lhc.beacon.header)

  ctx.lhc.layout = LinkedHChainsLayout(
    coupler:     ctx.layout.coupler,
    couplerHash: ctx.layout.couplerHash,
    least:       z,
    leastParent: ctx.lhc.beacon.header.parentHash,
    final:       z,
    finalHash:   rlpHeader.keccak256)

  # Save this header on the database so it needs not be fetched again from
  # somewhere else.
  ctx.dbStashHeaders(z, @[rlpHeader])

  # Save state
  discard ctx.dbStoreLinkedHChainsLayout()

  # Update range
  doAssert ctx.headersUnprocTotal() == 0
  doAssert ctx.headersUnprocBorrowed() == 0
  doAssert ctx.headersStagedQueueIsEmpty()
  ctx.headersUnprocSet(ctx.layout.coupler+1, ctx.layout.least-1)

  trace info & ": updated"
  true


proc mergeAdjacentChains(ctx: BeaconCtxRef): bool =
  const info = "mergeAdjacentChains"

  if ctx.lhc.layout.coupler+1 < ctx.lhc.layout.least or   # gap btw. `C` and `L`
     ctx.lhc.layout.coupler == ctx.lhc.layout.least:      # merged already
    return false

  # No overlap allowed!
  doAssert ctx.lhc.layout.coupler+1 == ctx.lhc.layout.least

  # Verify adjacent chains
  if ctx.lhc.layout.couplerHash != ctx.lhc.layout.leastParent:
    # FIXME: Oops -- any better idea than to defect?
    raiseAssert info & ": hashes do not match" &
      " C=" & ctx.lhc.layout.coupler.bnStr &
      " L=" & $ctx.lhc.layout.least.bnStr

  trace info & ": merging", C=ctx.lhc.layout.coupler.bnStr,
    L=ctx.lhc.layout.least.bnStr

  # Merge adjacent linked chains
  ctx.lhc.layout = LinkedHChainsLayout(
    coupler:     ctx.layout.final,               # `C`
    couplerHash: ctx.layout.finalHash,
    least:       ctx.layout.final,               # `L`
    leastParent: ctx.dbPeekParentHash(ctx.layout.final).expect "Hash32",
    final:       ctx.layout.final,               # `F`
    finalHash:   ctx.layout.finalHash)

  # Save state
  discard ctx.dbStoreLinkedHChainsLayout()

  true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateLinkedHChainsLayout*(ctx: BeaconCtxRef): bool =
  ## Update layout

  # Check whether there is something to do regarding beacon node change
  if ctx.lhc.beacon.changed:
    ctx.lhc.beacon.changed = false
    result = ctx.updateBeaconChange()

  # Check whether header downloading is done
  if ctx.mergeAdjacentChains():
    result = true


proc updateBlockRequests*(ctx: BeaconCtxRef): bool =
  ## Update block requests if there staged block queue is empty
  const info = "updateBlockRequests"

  let t = ctx.dbStateBlockNumber()
  if t < ctx.layout.coupler: # so the half open interval `(T,C]` is not empty

    # One can fill/import/execute blocks by number from `(T,C]`
    if ctx.blk.topRequest < ctx.layout.coupler:
      # So there is some space
      trace info & ": extending", T=t.bnStr, topReq=ctx.blk.topRequest.bnStr,
        C=ctx.layout.coupler.bnStr

      ctx.blocksUnprocCommit(
        0, max(t,ctx.blk.topRequest)+1, ctx.layout.coupler)
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
