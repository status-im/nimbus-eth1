# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/chronicles,
  ../../../../db/aristo/aristo_fetch,
  ../[mpt, state_db, worker_desc],
  ./session_helpers

logScope:
  topics = "snap sync"

type
  PivotStateNumPair* = tuple
    pivotNum: BlockNumber
    stateNum: BlockNumber

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc findPivotStateData(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[WalkStateData] =
  ## ..
  var state: WalkStateData
  for w in ctx.pool.mptAsm.walkStateData():
    if w.error.len == 0 and
       PivotOnTrie <= w.data.tag:
      if PivotOnTrie <= state.data.tag:             # is `w` another pivot?
        error info & ": Duplicate pivot on states cache DB",
          state=($state.data.number & "(" & $state.data.tag & ")"),
          dup=($w.data.number & "(" & $w.data.tag & ")")
        return err()                                # can that happen, at all?
        # End `if another-pivot`
      state = w                                     # found pivot
  if PivotOnTrie <= state.data.tag:
    return ok(move state)
  err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc sessionPivotStateNum*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[PivotStateNumPair] =
  ## Returns the pair of block numbers `(pivot-number,state-number)` where
  ## * `pivot-number` is derived from the MPT cache DB
  ## * `state-number` is the last saved state/checkpoint on the `Aristo` db
  var w: PivotStateNumPair
  w.stateNum = ctx.chain.baseTxFrame().aTx.fetchLastCheckpoint().valueOr:
    error info & ": Fetching last state block number failed", `error`=error
    return err()
  let pv = ctx.findPivotStateData(info).valueOr:
    trace info & ": No pivot available on states cache DB"
    return err()
  w.pivotNum = pv.data.number
  ok(w)

proc sessionPivotActivate*(
    ctx: SnapCtxRef;
    info: static[string];
      ): StateDataTag =
  ## Activate pivot from database iff
  ## * there is no pivot activated
  ## * the database has exactly on entry tagged at least `PivotOnTrie`
  ##   (includes logic successors of `PivotOnTrie`)
  if ctx.pool.pivot.isNone():
    let pvState = ctx.findPivotStateData(info).valueOr:
      return Untagged
    ctx.pool.pivot = Opt.some(pvState.root)
    return pvState.data.tag
  ctx.getPivotTag(info).valueOr:
    ctx.pool.pivot = Opt.none(StateRoot)            # reset stale pivot root
    Untagged

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
