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
  ../[mpt, worker_desc]

type
  SessionTicker* = object of RootObj
    msgAt*: Moment                                  # message while looping
    napAt*: Moment                                  # allow for thread switch

# ------------------------------------------------------------------------------
# Public helpers, session ticker related
# ------------------------------------------------------------------------------

method init*(status: var SessionTicker) {.base, gcsafe, raises: [].} =
  let now = Moment.now()
  status.msgAt = now + threadLogTimeLimit           # message while looping
  status.napAt = now + threadSwitchRunLimit         # allow for thread switch

template sessionTicker*(
   status: SessionTicker;                           # used as var parameter
   info: static[string];
   code: untyped;                                   # e.g. logging directive
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

# ----------------

proc countTrieNodes*(
    ctx: SnapCtxRef;
      ): tuple[nAccNodes, nStoNodes: uint64, ela: Duration] =
  ## Simple stored nodes counter
  let
    db = ctx.pool.mptAsm
    start = Moment.now()
  for _ in db.walkAccTrie():
    result.nAccNodes.inc
  for _ in db.walkStoTrie():
    result.nStoNodes.inc
  result.ela = Moment.now() - start

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
