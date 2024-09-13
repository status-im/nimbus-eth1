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
  ../../sync_desc,
  ../worker_desc,
  ./update/metrics,
  "."/[db, headers_unproc]

logScope:
  topics = "flare update"

const extraTraceMessages = false
  ## Enabled additional logging noise

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
  ##     | <-- linked --> |
  ##
  const info = "updateBeaconChange"

  var z = ctx.lhc.beacon.header.number

  # Need: `F < Z` and `B == L`
  if z != 0 and z <= ctx.layout.final:       # violates `F < Z`
    when extraTraceMessages:
      trace info & ": not applicable",
        Z=("#" & $z), F=("#" & $ctx.layout.final)
    return false

  if ctx.layout.base != ctx.layout.least:    # violates `B == L`
    when extraTraceMessages:
      trace info & ": not applicable",
        B=("#" & $ctx.layout.base), L=("#" & $ctx.layout.least)
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
  ctx.headersUnprocMerge(ctx.layout.base+1, ctx.layout.least-1)

  when extraTraceMessages:
    trace info & ": updated"
  true


proc mergeAdjacentChains(ctx: FlareCtxRef): bool =
  const info = "mergeAdjacentChains"

  if ctx.lhc.layout.base + 1 < ctx.lhc.layout.least or # gap betw `B` and `L`
     ctx.lhc.layout.base == ctx.lhc.layout.least:      # merged already
    return false

  # No overlap allowed!
  doAssert ctx.lhc.layout.base + 1 == ctx.lhc.layout.least

  when extraTraceMessages:
    trace info & ": merging", B=ctx.lhc.layout.base.bnStr,
      L=ctx.lhc.layout.least.bnStr

  # Verify adjacent chains
  if ctx.lhc.layout.baseHash != ctx.lhc.layout.leastParent:
    # FIXME: Oops -- any better idea than to defect?
    raiseAssert info & ": hashes do not match" &
      " B=#" & $ctx.lhc.layout.base & " L=#" & $ctx.lhc.layout.least

  # Merge adjacent linked chains
  ctx.lhc.layout = LinkedHChainsLayout(
    base:        ctx.layout.final,
    baseHash:    ctx.layout.finalHash,
    least:       ctx.layout.final,
    leastParent: ctx.dbPeekParentHash(ctx.layout.final).expect "Hash256",
    final:       ctx.layout.final,
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


proc updateMetrics*(ctx: FlareCtxRef) =
  ctx.updateMetricsImpl()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
