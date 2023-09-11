# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  results,
  ../aristo_desc,
  "."/[filter_merge, filter_reverse]

type
  UpdateState = enum
    Initial = 0
    Updated,
    Finished

  UpdateSiblingsRef* = ref object
    ## Update transactional context
    state: UpdateState                       ## No `rollback()` after `commit()`
    db: AristoDbRef                          ## Main database access
    roFilters: seq[(AristoDbRef,FilterRef)]  ## Rollback data
    rev: FilterRef                           ## Reverse filter set up

# ------------------------------------------------------------------------------
# Public contructor, commit, rollback
# ------------------------------------------------------------------------------

proc rollback*(ctx: UpdateSiblingsRef) =
  ## Rollback any changes made by the `update()` function. Subsequent
  ## `rollback()` or `commit()` calls will be without effect.
  if ctx.state == Updated:
    for (d,f) in ctx.roFilters:
      d.roFilter = f
  ctx.state = Finished


proc commit*(ctx: UpdateSiblingsRef): Result[void,AristoError] =
  ## Accept updates. Subsequent `rollback()` calls will be without effect.
  if ctx.state != Updated:
    ctx.rollback()
    return err(FilSiblingsCommitUnfinshed)
  ctx.db.roFilter = FilterRef(nil)
  ctx.state = Finished
  ok()

proc commit*(
  rc: Result[UpdateSiblingsRef,AristoError];
    ): Result[void,AristoError] =
  ## Variant of `commit()` for joining with `update()`
  (? rc).commit()


proc init*(
    T: type UpdateSiblingsRef;                       # Context type
    db: AristoDbRef;                                 # Main database
      ): Result[T,AristoError] =
  ## Set up environment for installing the reverse of the `db` argument current
  ## read-only filter onto every associated descriptor referring to the same
  ## database.
  if  not db.isCentre:
    return err(FilBackendRoMode)

  func fromVae(err: (VertexID,AristoError)): AristoError =
    err[1]

  # Filter rollback context
  ok T(
    db:  db,
    rev: ? db.revFilter(db.roFilter).mapErr fromVae) # Reverse filter

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc update*(ctx: UpdateSiblingsRef): Result[UpdateSiblingsRef,AristoError] =
  ## This function installs the reverse of the `init()` argument `db` current
  ## read-only filter onto every associated descriptor referring to the same
  ## database. If the function fails, a `rollback()` is called automatically.
  ##
  ## This function might do some real work so it was detached from `init()` so
  ## it can be called late but before the physical database is updated.
  ##
  if ctx.state == Initial:
    ctx.state = Updated
    let db = ctx.db
    # Update distributed filters. Note that the physical backend database
    # must not have been updated, yet. So the new root key for the backend
    # will be `db.roFilter.trg`.
    for w in db.forked:
      let rc = db.merge(w.roFilter, ctx.rev, db.roFilter.trg)
      if rc.isErr:
        ctx.rollback()
        return err(rc.error[1])
      ctx.roFilters.add (w, w.roFilter)
      w.roFilter = rc.value
  ok(ctx)

proc update*(
    rc: Result[UpdateSiblingsRef,AristoError]
      ): Result[UpdateSiblingsRef,AristoError] =
  ## Variant of `update()` for joining with `init()`
  (? rc).update()

# ------------------------------------------------------------------------------
# Public getter
# ------------------------------------------------------------------------------

func rev*(ctx: UpdateSiblingsRef): FilterRef =
  ## Getter, returns the reverse of the `init()` argument `db` current
  ## read-only filter.
  ctx.rev

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

