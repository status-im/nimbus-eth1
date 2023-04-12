#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronos,
  ../../../sync_desc,
  ../../worker_desc

type
  PlayVoidFutureCtxFn* = proc(
    ctx: SnapCtxRef): Future[void]
      {.gcsafe, raises: [CatchableError].}

  PlayVoidFutureBuddyFn* = proc(
    buddy: SnapBuddyRef): Future[void]
      {.gcsafe, raises: [CatchableError].}

  PlayBoolBuddyBoolIntFn* = proc(
    buddy: SnapBuddyRef; last: bool; laps: int): bool
      {.gcsafe, raises: [CatchableError].}

  PlaySyncSpecs* = ref object of RootRef
    ## Holds sync mode specs & methods for a particular sync state
    pool*: PlayBoolBuddyBoolIntFn
    daemon*: PlayVoidFutureCtxFn
    single*: PlayVoidFutureBuddyFn
    multi*: PlayVoidFutureBuddyFn

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc playSyncSpecs*(ctx: SnapCtxRef): PlaySyncSpecs =
  ## Getter
  ctx.pool.syncMode.tab[ctx.pool.syncMode.active].PlaySyncSpecs

proc `playMode=`*(ctx: SnapCtxRef; val: SnapSyncModeType) =
  ## Setter
  ctx.pool.syncMode.active = val

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
