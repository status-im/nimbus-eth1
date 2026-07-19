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
  ../[mpt, state_db, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getPivotData(
    ctx: SnapCtxRef,
    info: static[string];
      ): Opt[(StateRoot,CacheStateData)] =
  let root = ctx.pool.pivot.valueOr:
    return err()
  var data = ctx.pool.cacheDB.getStateData(root).valueOr:
    error info & ": Cached pivot inaccessible", root=root.toStr, `error`=error
    return err()
  ok((root, move data))

proc findPivotStateData(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[WalkStateData] =
  var state: WalkStateData
  for w in ctx.pool.cacheDB.walkStateData():
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

proc sessionPivotNum*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[BlockNumber] =
  ctx.getPivotData(info).isErrOr:
    return ok(value[1].number)
  err()

proc sessionPivotTag*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[StateDataTag] =
  ctx.getPivotData(info).isErrOr:
    return ok(value[1].tag)
  err()

proc sessionPivotTagUpdate*(
    ctx: SnapCtxRef;
    tag: StateDataTag;
    info: static[string];
      ): Opt[void] =
  var (root,pivot) = ctx.getPivotData(info).valueOr:
    return err()
  pivot.tag = tag
  ctx.pool.cacheDB.putStateData(root,pivot).isOkOr:
    error info & ": Error updating cached pivot",
      root=root.Hash32.short, `error`=error
    return err()
  ok()

proc sessionPivotNumCached*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[BlockNumber] =
  ## Returns the pivot block number derived from the MPT cache DB
  let pv = ctx.findPivotStateData(info).valueOr:
    trace info & ": No pivot available on states cache DB"
    return err()
  ok pv.data.number

proc sessionPivotActivateCached*(
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
  ctx.getPivotData(info).isErrOr:
    return value[1].tag
  ctx.pool.pivot = Opt.none(StateRoot)              # reset stale pivot root
  Untagged

proc sessionPivotResetCached*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[void] =
  ## Disable pivot on database and `ctx` argument descriptor
  ctx.pool.pivot = Opt.none(StateRoot)
  var state = ctx.findPivotStateData(info).valueOr:
    return ok()
  state.data.tag = Untagged
  ctx.pool.cacheDB.putStateData(state.root, state.data).isOkOr:
    trace info & ": Cannot reset pivot on cache DB",
      root=state.root.toStr, number=state.data.number
    return err()
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
