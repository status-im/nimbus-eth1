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
  std/[algorithm, sequtils],
  ".."/[aristo_constants, aristo_desc],
  ./filter_desc

const
  ZeroQidPair = (QueueID(0),QueueID(0))

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func `+`*(a: QueueID; b: uint): QueueID = (a.uint64+b.uint64).QueueID
func `-`*(a: QueueID; b: uint): QueueID = (a.uint64-b.uint64).QueueID

func `<`(a: static[uint]; b: QueueID): bool = QueueID(a) < b

func globalQid(queue: int, qid: QueueID): QueueID =
  QueueID((queue.uint64 shl 62) or qid.uint64)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func fifoLen(
    fifo: (QueueID,QueueID);
    wrap: QueueID;
     ): uint =
  ## Number of entries in wrap-arounfd fifo organised with `fifo[0]` is the
  ## oldest entry and`fifo[1]` is the latest/newest entry.
  ##
  if fifo[0] == 0:
    return 0

  if fifo[0] <= fifo[1]:
    # Filling up
    # ::
    #  |             :
    #  |  fifo[0]--> 3
    #  |             4
    #  |             5 <--fifo[1]
    #  |             :
    #
    return ((fifo[1] + 1) - fifo[0]).uint

  else:
    # After wrap aound
    # ::
    #  |             :
    #  |             3 <--fifo[1]
    #  |             4
    #  |  fifo[0]--> 5
    #  |             :
    #  |            wrap
    return ((fifo[1] + 1) + (wrap - fifo[0])).uint


func fifoAdd(
    fifo: (QueueID,QueueID);
    wrap: QueueID;
      ): tuple[doDel: QueueID, fifo: (QueueID,QueueID)] =
  ## Add an entry to the wrap-arounfd fifo organised with `fifo[0]` is the
  ## oldest entry and`fifo[1]` is the latest/newest entry.
  ##
  if fifo[0] == 0:
    return (QueueID(0), (QueueID(1),QueueID(1)))

  if fifo[0] <= fifo[1]:
    if fifo[1] < wrap:
      # Filling up
      # ::
      #  |             :
      #  |  fifo[0]--> 3
      #  |             4
      #  |             5 <--fifo[1]
      #  |             :
      #
      return (QueueID(0), (fifo[0],fifo[1]+1))
    elif 1 < fifo[0]:
      # Wrapping
      # ::
      #  |             :
      #  |  fifo[0]--> 3
      #  |             4
      #  |             :
      #  |            wrap <--fifo[1]
      #
      return (QueueID(0), (fifo[0],QueueID(1)))
    elif 1 < wrap:
      # Wrapping and flushing out
      # ::
      #  |  fifo[0]--> 1
      #  |             2
      #  |             :
      #  |            wrap <--fifo[1]
      #
      return (QueueID(1), (QueueID(2),QueueID(1)))
    else:
      # Single entry FIFO
      return (QueueID(1), (QueueID(1),QueueID(1)))

  else:
    if fifo[1] + 1 < fifo[0]:
      # Filling up
      # ::
      #  |             :
      #  |             3 <--fifo[1]
      #  |             4
      #  |  fifo[0]--> 5
      #  |             :
      #  |            wrap
      return (QueueID(0), (fifo[0],fifo[1]+1))
    elif fifo[0] < wrap:
      # Flushing out
      # ::
      #  |             :
      #  |             4 <--fifo[1]
      #  |  fifo[0]--> 5
      #  |             :
      #  |            wrap
      return (fifo[0], (fifo[0]+1,fifo[1]+1))
    else:
      # Wrapping and flushing out
      # ::
      #  |              :
      #  |            wrap-1 <--fifo[1]
      #  |  fifo[0]--> wrap
      return (wrap, (QueueID(1),wrap))


func fifoDel(
    fifo: (QueueID,QueueID);
    nDel: uint;
    wrap: QueueID;
      ): tuple[doDel: seq[(QueueID,QueueID)], fifo: (QueueID,QueueID)] =
  ## Delete a the range `nDel` of filter IDs from the FIFO. The entries to be
  ## deleted are taken from the oldest ones added.
  ##
  if fifo[0] == 0:
    return (EmptyQidPairSeq, ZeroQidPair)

  if fifo[0] <= fifo[1]:
    # Take off the left end from `fifo[0] .. fifo[1]`
    # ::
    #  |             :
    #  |  fifo[0]--> 3            ^
    #  |             4            | to be deleted
    #  |             5            v
    #  |             6 <--fifo[1]
    #  |             :
    #
    if nDel.uint64 <= fifo[1] - fifo[0]:
      return (@[(fifo[0], fifo[0] + nDel - 1)], (fifo[0] + nDel, fifo[1]))
    else:
      return (@[fifo], ZeroQidPair)

  else:
    if nDel.uint64 <= (wrap - fifo[0] + 1):
      # Take off the left end from `fifo[0] .. wrap`
      # ::
      #  |             :
      #  |             3 <--fifo[1]
      #  |             4
      #  |  fifo[0]--> 5            ^
      #  |             6            | to be deleted
      #  |             7            v
      #  |             :
      #  |            wrap
      #
      let topRange = (fifo[0], fifo[0] + nDel - 1)
      if  nDel.uint64 < (wrap - fifo[0] + 1):
        return (@[topRange], (fifo[0] + nDel, fifo[1]))
      else:
        return (@[topRange], (QueueID(1), fifo[1]))

    else:
      # Interval `fifo[0] .. wrap` fully deleted, check `1 .. fifo[0]`
      # ::
      #  |             1            ^
      #  |             2            | to be deleted
      #  |             :            v
      #  |             6
      #  |             7<--fifo[1]
      #  |  fifo[0]--> 8            ^
      #  |             9            | to be deleted
      #  |             :            :
      #  |            wrap          v
      #
      let
        topRange = (fifo[0], wrap)
        nDelLeft = nDel.uint64 - (wrap - fifo[0] + 1)

      # Take off the left end from `QueueID(1) .. fifo[1]`
      if nDelLeft <= fifo[1] - QueueID(0):
        let bottomRange = (QueueID(1), QueueID(nDelLeft))
        if nDelLeft < fifo[1] - QueueID(0):
          return (@[bottomRange, topRange], (QueueID(nDelLeft+1), fifo[1]))
        else:
          return (@[bottomRange, topRange], ZeroQidPair)
      else:
        # Delete all available
        return (@[(QueueID(1), fifo[1]), (fifo[0], wrap)], ZeroQidPair)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc stats*(
    ctx: openArray[tuple[size, width: int]];
      ): tuple[maxQueue: int, minCovered: int, maxCovered: int] =
  ## Number of maximally stored and covered queued entries for the argument
  ## layout `ctx`. The resulting value of `maxQueue` entry is the maximal
  ## number of database slots needed, the `minCovered` and `maxCovered` entry
  ## indicate the rancge of the backlog foa a fully populated database.
  var step = 1

  for n in 0 ..< ctx.len:
    step *= ctx[n].width + 1
    let size = ctx[n].size + ctx[(n+1) mod ctx.len].width
    result.maxQueue += size.int
    result.minCovered += (ctx[n].size * step).int
    result.maxCovered += (size * step).int

proc stats*(
    ctx: openArray[tuple[size, width, wrap: int]];
      ): tuple[maxQueue: int, minCovered: int, maxCovered: int] =
  ## Variant of `stats()`
  ctx.toSeq.mapIt((it[0],it[1])).stats

proc stats*(
    ctx: QidLayoutRef;
      ): tuple[maxQueue: int, minCovered: int, maxCovered: int] =
  ## Variant of `stats()`
  ctx.q.toSeq.mapIt((it[0].int,it[1].int)).stats


proc addItem*(
    fifo: QidSchedRef;
      ): tuple[exec: seq[QidAction], fifo: QidSchedRef] =
  ## Get the instructions for adding a new slot to the cascades queues. The
  ## argument `fifo` is a complete state of the addresses a cascaded *FIFO*
  ## when applied to a database. Only the *FIFO* queue addresses are needed
  ## in order to describe how to add another item.
  ##
  ## Return value is a list of instructions what to do when adding a new item
  ## and the new state of the cascaded *FIFO*.
  ##
  ## The following instructions may be returned:
  ## ::
  ##    SaveQid <queue-id>         -- Store a new item under the address
  ##                               -- <queue-id> on the database.
  ##
  ##    HoldQid <from-id>..<to-id> -- Move the records accessed by the argument
  ##                               -- addresses from the database to the right
  ##                               -- end of the local hold queue. The age of
  ##                               -- the items on the hold queue increases
  ##                               -- left to right.
  ##
  ##    DequQid <queue-id>         -- Merge items from the hold queue into a
  ##                               -- new item and store it under the address
  ##                               -- <queue-id> on the database. Clear the
  ##                               -- the hold queue.
  ##
  let
    ctx = fifo.ctx.q
  var
    state = fifo.state
    deferred: seq[QidAction]   # carry over to next sub-queue
    revActions: seq[QidAction] # instructions in reverse order

  for n in 0 ..< ctx.len:
    if state.len < n + 1:
      state.setlen(n + 1)

    let
      overlapWidth = ctx[(n+1) mod ctx.len].width
      carryOverSize = ctx[n].size + overlapWidth
      stateLen = state[n].fifoLen ctx[n].wrap

    if stateLen < carryOverSize:
      state[n] = state[n].fifoAdd(ctx[n].wrap).fifo
      let qQidAdded = n.globalQid state[n][1]
      if  0 < n:
        revActions.add QidAction(op: DequQid, qid: qQidAdded)
      else:
        revActions.add QidAction(op: SaveQid, qid: qQidAdded)
      if 0 < deferred.len:
        revActions &= deferred
      break

    else:
      # Full queue segment, carry over to next one
      let
        extra = stateLen - carryOverSize # should be zero
        qDel = state[n].fifoDel(extra + overlapWidth + 1, ctx[n].wrap)
        qAdd = qDel.fifo.fifoAdd ctx[n].wrap
        qFidAdded = n.globalQid qAdd.fifo[1]

      if 0 < n:
        revActions.add QidAction(op: DequQid, qid: qFidAdded)
      else:
        revActions.add QidAction(op: SaveQid, qid: qFidAdded)

      if 0 < deferred.len:
        revActions &= deferred
        deferred.setLen(0)

      for w in qDel.doDel:
        deferred.add QidAction(
          op:  HoldQid,
          qid: n.globalQid w[0],
          xid: n.globalQid w[1])
      state[n] = qAdd.fifo

    # End loop

  (revActions.reversed, QidSchedRef(ctx: fifo.ctx, state: state))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
