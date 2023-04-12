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

  PlayVoidCtxFn* = proc(
    ctx: SnapCtxRef)
      {.gcsafe, raises: [CatchableError].}


  PlayVoidFutureBuddyFn* = proc(
    buddy: SnapBuddyRef): Future[void]
      {.gcsafe, raises: [CatchableError].}

  PlayBoolBuddyBoolIntFn* = proc(
    buddy: SnapBuddyRef; last: bool; laps: int): bool
      {.gcsafe, raises: [CatchableError].}

  PlayBoolBuddyFn* = proc(
    buddy: SnapBuddyRef): bool
      {.gcsafe, raises: [CatchableError].}

  PlayVoidBuddyFn* = proc(
    buddy: SnapBuddyRef)
      {.gcsafe, raises: [CatchableError].}


  PlaySyncSpecs* = ref object of RootRef
    ## Holds sync mode specs & methods for a particular sync state
    setup*: PlayVoidCtxFn
    release*: PlayVoidCtxFn
    start*: PlayBoolBuddyFn
    stop*: PlayVoidBuddyFn
    pool*: PlayBoolBuddyBoolIntFn
    daemon*: PlayVoidFutureCtxFn
    single*: PlayVoidFutureBuddyFn
    multi*: PlayVoidFutureBuddyFn

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc playMethod*(ctx: SnapCtxRef): PlaySyncSpecs =
  ## Getter
  ctx.pool.syncMode.tab[ctx.pool.syncMode.active].PlaySyncSpecs

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
