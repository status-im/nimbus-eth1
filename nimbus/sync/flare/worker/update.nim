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
  topics = "flare update"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updateBeaconChange(ctx: FlareCtxRef): bool =
  ##
  ## Layout (see (3) in README):
  ## ::
  ##     G             B==L==F                  Z
  ##     o----------------o---------------------o---->
  ##     | <-- linked --> |
  ##
  ## or
  ## ::
  ##    G==Z            B==L==F
  ##     o----------------o-------------------------->
  ##     | <-- linked --> |
  ##
  ## with `Z == beacon.header.number` or `Z == 0`
  ##
  ## to be updated to
  ## ::
  ##     G               B==L                 L'==F'
  ##     o----------------o---------------------o---->
  ##     | <-- linked --> | <-- unprocessed --> |
  ##
  const info = "updateBeaconChange"

  var z = ctx.lhc.beacon.header.number

  # Need: `F < Z` and `B == L`
  if z != 0 and z <= ctx.layout.final:       # violates `F < Z`
    trace info & ": not applicable", Z=z.bnStr, F=ctx.layout.final.bnStr
    return false

  if ctx.layout.base != ctx.layout.least:    # violates `B == L`
    trace info & ": not applicable",
      B=ctx.layout.base.bnStr, L=ctx.layout.least.bnStr
    return false

  # Check consistency: `B == L <= F` for maximal `B` => `L == F`
  doAssert ctx.layout.least == ctx.layout.final

  let rlpHeader = rlp.encode(ctx.lhc.beacon.header)

  ctx.lhc.layout = LinkedHChainsLayout(
    base:        ctx.layout.base,
    baseHash:    ctx.layout.baseHash,
    least:       z,
    leastParent: ctx.lhc.beacon.header.parentHash,
    final:       z,
    finalHash:   rlpHeader.keccakHash)

  # Save this header on the database so it needs not be fetched again from
  # somewhere else.
  ctx.dbStashHeaders(z, @[rlpHeader])

  # Save state
  discard ctx.dbStoreLinkedHChainsLayout()

  # Update range
  doAssert ctx.headersUnprocTotal() == 0
  doAssert ctx.headersUnprocBorrowed() == 0
  doAssert ctx.headersStagedQueueIsEmpty()
  ctx.headersUnprocSet(ctx.layout.base+1, ctx.layout.least-1)

  trace info & ": updated"
  true


proc mergeAdjacentChains(ctx: FlareCtxRef): bool =
  const info = "mergeAdjacentChains"

  if ctx.lhc.layout.base + 1 < ctx.lhc.layout.least or # gap betw `B` and `L`
     ctx.lhc.layout.base == ctx.lhc.layout.least:      # merged already
    return false

  # No overlap allowed!
  doAssert ctx.lhc.layout.base + 1 == ctx.lhc.layout.least

  # Verify adjacent chains
  if ctx.lhc.layout.baseHash != ctx.lhc.layout.leastParent:
    # FIXME: Oops -- any better idea than to defect?
    raiseAssert info & ": hashes do not match" &
      " B=" & ctx.lhc.layout.base.bnStr & " L=" & $ctx.lhc.layout.least.bnStr

  trace info & ": merging", B=ctx.lhc.layout.base.bnStr,
    L=ctx.lhc.layout.least.bnStr

  # Merge adjacent linked chains
  ctx.lhc.layout = LinkedHChainsLayout(
    base:        ctx.layout.final,               # `B`
    baseHash:    ctx.layout.finalHash,
    least:       ctx.layout.final,               # `L`
    leastParent: ctx.dbPeekParentHash(ctx.layout.final).expect "Hash256",
    final:       ctx.layout.final,               # `F`
    finalHash:   ctx.layout.finalHash)

  # Save state
  discard ctx.dbStoreLinkedHChainsLayout()

  true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateLinkedHChainsLayout*(ctx: FlareCtxRef): bool =
  ## Update layout

  # Check whether there is something to do regarding beacon node change
  if ctx.lhc.beacon.changed:
    ctx.lhc.beacon.changed = false
    result = ctx.updateBeaconChange()

  # Check whether header downloading is done
  if ctx.mergeAdjacentChains():
    result = true


proc updateBlockRequests*(ctx: FlareCtxRef): bool =
  ## Update block requests if there staged block queue is empty
  const info = "updateBlockRequests"

  let t = ctx.dbStateBlockNumber()
  if t < ctx.layout.base: # so the half open interval `(T,B]` is not empty

    # One can fill/import/execute blocks by number from `(T,B]`
    if ctx.blk.topRequest < ctx.layout.base:
      # So there is some space
      trace info & ": extending", T=t.bnStr, topReq=ctx.blk.topRequest.bnStr,
        B=ctx.layout.base.bnStr

      ctx.blocksUnprocCommit(0, max(t,ctx.blk.topRequest) + 1, ctx.layout.base)
      ctx.blk.topRequest = ctx.layout.base
      return true

  false


proc updateMetrics*(ctx: FlareCtxRef) =
  let now = Moment.now()
  if ctx.pool.nextUpdate < now:
    ctx.updateMetricsImpl()
    ctx.pool.nextUpdate = now + metricsUpdateInterval

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
