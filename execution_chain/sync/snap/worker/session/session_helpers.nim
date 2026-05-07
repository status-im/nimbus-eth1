# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronicles, chronos],
  ../worker_desc

type
  SessionTicker* = object
    stateInx*: int                                  # 1 .. `nStates`
    nStates*: int
    distance*: uint64
    msgAt*: Moment                                  # message while looping
    napAt*: Moment                                  # allow for thread switch

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc init*(_: type SessionTicker, nStates = 0): SessionTicker =
  SessionTicker(
    nStates: nStates,
    msgAt: Moment.now() + threadLogTimeLimit,       # message while looping
    napAt: Moment.now() + threadSwitchRunLimit)     # allow for thread switch

template sessionTicker*(
   status: SessionTicker;                          # used as var parameter
   info: static[string];
   code: untyped;                                  # e.g. logging directive
     ): Opt[ErrorType] =
  ## Async/template
  ##
  ## Run recurrent jobs an check for termination
  ##
  var bodyRc = Opt.none(ErrorType)
  block body:
    # Occasionally do the keep alive thingy
    if status.msgAt < Moment.now():
      code
      status.msgAt = Moment.now() + threadLogTimeLimit

    # And allow task switching, sometimes
    if status.napAt < Moment.now():
      try:
        await sleepAsync threadSwitchTimeSlot
      except CancelledError as e:
        chronicles.error info & ": Async wait cancelled",
          error=($e.name & "(" & e.msg & ")")
        bodyRc = Opt.some(ECancelledError)
        break body

      # Check for scheduler shutdown after thread switch
      if not ctx.daemon:
        chronicles.error info & ": Daemon session terminated"
        bodyRc = Opt.some(ECancelledError)
        break body

      status.napAt = Moment.now() + threadSwitchRunLimit

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
