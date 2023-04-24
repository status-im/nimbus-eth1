#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronos,
  ../../worker_desc

type
  PassVoidFutureCtxFn* = proc(
    ctx: SnapCtxRef): Future[void]
      {.gcsafe, raises: [CatchableError].}

  PassVoidCtxFn* = proc(
    ctx: SnapCtxRef)
      {.gcsafe, raises: [CatchableError].}


  PassVoidFutureBuddyFn* = proc(
    buddy: SnapBuddyRef): Future[void]
      {.gcsafe, raises: [CatchableError].}

  PassBoolBuddyBoolIntFn* = proc(
    buddy: SnapBuddyRef; last: bool; laps: int): bool
      {.gcsafe, raises: [CatchableError].}

  PassBoolBuddyFn* = proc(
    buddy: SnapBuddyRef): bool
      {.gcsafe, raises: [CatchableError].}

  PassVoidBuddyFn* = proc(
    buddy: SnapBuddyRef)
      {.gcsafe, raises: [CatchableError].}


  PassActorRef* = ref object of RootRef
    ## Holds sync mode specs & methods for a particular sync state
    setup*: PassVoidCtxFn
    release*: PassVoidCtxFn
    start*: PassBoolBuddyFn
    stop*: PassVoidBuddyFn
    pool*: PassBoolBuddyBoolIntFn
    daemon*: PassVoidFutureCtxFn
    single*: PassVoidFutureBuddyFn
    multi*: PassVoidFutureBuddyFn

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc passActor*(ctx: SnapCtxRef): PassActorRef =
  ## Getter
  ctx.pool.syncMode.tab[ctx.pool.syncMode.active].PassActorRef

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
