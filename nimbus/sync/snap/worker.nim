# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Sync mode pass multiplexer
## ==========================
##
## Pass state diagram:
## ::
##    <init> -> <snap-sync> -> <full-sync> ---+
##                                 ^          |
##                                 |          |
##                                 +----------+
##
{.push raises: [].}

import
  chronicles,
  chronos,
  ./range_desc,
  ./worker/pass,
  ./worker_desc

logScope:
  topics = "snap-worker"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template ignoreException(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    error "Exception at " & info & ":", name=($e.name), msg=(e.msg)

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef): bool =
  ## Global set up
  ctx.passInitSetup()
  ignoreException("setup"):
    ctx.passActor.setup(ctx)
  true

proc release*(ctx: SnapCtxRef) =
  ## Global clean up
  ignoreException("release"):
    ctx.passActor.release(ctx)
  ctx.passInitRelease()

proc start*(buddy: SnapBuddyRef): bool =
  ## Initialise worker peer
  ignoreException("start"):
    result = buddy.ctx.passActor.start(buddy)

proc stop*(buddy: SnapBuddyRef) =
  ## Clean up this peer
  ignoreException("stop"):
    buddy.ctx.passActor.stop(buddy)

# ------------------------------------------------------------------------------
# Public functions, sync handler multiplexers
# ------------------------------------------------------------------------------

proc runDaemon*(ctx: SnapCtxRef) {.async.} =
  ## Sync processsing multiplexer
  ignoreException("runDaemon"):
    await ctx.passActor.daemon(ctx)

proc runSingle*(buddy: SnapBuddyRef) {.async.} =
  ## Sync processsing multiplexer
  ignoreException("runSingle"):
    await buddy.ctx.passActor.single(buddy)

proc runPool*(buddy: SnapBuddyRef, last: bool; laps: int): bool =
  ## Sync processsing multiplexer
  ignoreException("runPool"):
    result = buddy.ctx.passActor.pool(buddy,last,laps)

proc runMulti*(buddy: SnapBuddyRef) {.async.} =
  ## Sync processsing multiplexer
  ignoreException("runMulti"):
    await buddy.ctx.passActor.multi(buddy)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
