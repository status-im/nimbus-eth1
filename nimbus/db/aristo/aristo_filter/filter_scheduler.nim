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

type
  QuFilMap* = proc(qid: QueueID): FilterID {.gcsafe, raises: [].}
    ## The map `fn: QueueID -> FilterID` can be augmented to a strictly
    ## *decreasing* map `g: {0 .. N} -> FilterID`, with `g = fn([])`
    ##
    ## * `i < j` => `fn(fifo[j]) < fn(fifo[i])`
    ##
    ## for a `fifo` of type `QidSchedRef`, `N = fifo.len` and the function
    ## `[]: {0 .. N} -> QueueID` as defined below.
    ##
    ## This *decreasing* requirement can be seen as a generalisation of a
    ## block chain scenario with `i`, `j`  backward steps into the past and
    ## the `FilterID` as the block number.
    ##
    ## In order to flag an error, `FilterID(0)` must be returned.

const
  ZeroQidPair = (QueueID(0),QueueID(0))

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

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

func stats*(
    ctx: openArray[tuple[size, width: int]];       # Schedule layout
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

func stats*(
    ctx: openArray[tuple[size, width, wrap: int]]; # Schedule layout
      ): tuple[maxQueue: int, minCovered: int, maxCovered: int] =
  ## Variant of `stats()`
  ctx.toSeq.mapIt((it[0],it[1])).stats

func stats*(
    ctx: QidLayoutRef;                             # Cascaded fifos descriptor
      ): tuple[maxQueue: int, minCovered: int, maxCovered: int] =
  ## Variant of `stats()`
  ctx.q.toSeq.mapIt((it[0].int,it[1].int)).stats


func addItem*(
    fifo: QidSchedRef;                             # Cascaded fifos descriptor
      ): tuple[exec: seq[QidAction], fifo: QidSchedRef] =
  ## Get the instructions for adding a new slot to the cascades queues. The
  ## argument `fifo` is a complete state of the addresses of a cascaded *FIFO*
  ## when applied to a database. Only the *FIFO* queue addresses are needed
  ## in order to describe how to add another item.
  ##
  ## The function returns a list of instructions what to do when adding a new
  ## item and the new state of the cascaded *FIFO*. The following instructions
  ## may be returned:
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
  ##    DelQid <queue-id>          -- Delete item. This happens if the last
  ##                               -- oberflow queue needs to make space for
  ##                               -- another item.
  ##
  let
    ctx = fifo.ctx.q
  var
    state = fifo.state
    deferred: seq[QidAction]   # carry over to next sub-queue
    revActions: seq[QidAction] # instructions in reverse order

  for n in 0 ..< ctx.len:
    if state.len < n + 1:
      state.setLen(n + 1)

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
        deferred.setLen(0)
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

  # Delete item from final overflow queue. There is only one as `overlapWidth`
  # is `ctx[0]` which is `0`
  if 0 < deferred.len:
    revActions.add QidAction(
      op:  DelQid,
      qid: deferred[0].qid)

  (revActions.reversed, QidSchedRef(ctx: fifo.ctx, state: state))


func fetchItems*(
    fifo: QidSchedRef;                             # Cascaded fifos descriptor
    size: int;                                     # Leading items to merge
      ): tuple[exec: seq[QidAction], fifo: QidSchedRef] =
  ## Get the instructions for extracting the latest `size` items from the
  ## cascaded queues. argument `fifo` is a complete state of the addresses of
  ## a cascaded *FIFO* when applied to a database. Only the *FIFO* queue
  ## addresses are used in order to describe how to add another item.
  ##
  ## The function returns a list of instructions what to do when adding a new
  ## item and the new state of the cascaded *FIFO*. The following instructions
  ## may be returned:
  ## ::
  ##    HoldQid <from-id>..<to-id> -- Move the records accessed by the argument
  ##                               -- addresses from the database to the right
  ##                               -- end of the local hold queue. The age of
  ##                               -- the items on the hold queue increases
  ##                               -- left to right.
  ##
  ## The extracted items will then be available from the hold queue.
  var
    actions: seq[QidAction]
    state = fifo.state

  if 0 < size:
    var size = size.uint64

    for n in 0 ..< fifo.state.len:
      let q = fifo.state[n]
      if q[0] == 0:
        discard

      elif q[0] <= q[1]:
        # Single file
        # ::
        #  |          :
        #  |  q[0]--> 3
        #  |          4
        #  |          5 <--q[1]
        #  |           :
        #
        let qSize = q[1] - q[0] + 1

        if size <= qSize:
          if size < qSize:
            state[n][1] = q[1] - size
          elif state.len == n + 1:
            state.setLen(n)
          else:
            state[n] = (QueueID(0), QueueID(0))
          actions.add QidAction(
            op:  HoldQid,
            qid: n.globalQid(q[1] - size + 1),
            xid: n.globalQid q[1])
          break

        actions.add QidAction(
          op:  HoldQid,
          qid: n.globalQid q[0],
          xid: n.globalQid q[1])
        state[n] = (QueueID(0), QueueID(0))

        size -= qSize # Otherwise continue

      else:
        # Wrap aound, double files
        # ::
        #  |          :
        #  |          3 <--q[1]
        #  |          4
        #  |  q[0]--> 5
        #  |          :
        #  |         wrap
        let
          wrap = fifo.ctx.q[n].wrap
          qSize1 = q[1] - QueueID(0)

        if size <= qSize1:
          if size == qSize1:
            state[n][1] = wrap
          else:
            state[n][1] = q[1] - size
          actions.add QidAction(
            op:  HoldQid,
            qid: n.globalQid(q[1] - size + 1),
            xid: n.globalQid q[1])
          break

        actions.add QidAction(
          op:  HoldQid,
          qid: n.globalQid QueueID(1),
          xid: n.globalQid q[1])
        size -= qSize1 # Otherwise continue

        let qSize0 = wrap - q[0] + 1

        if size <= qSize0:
          if size < qSize0:
            state[n][1] = wrap - size
          elif state.len == n + 1:
            state.setLen(n)
          else:
            state[n] = (QueueID(0), QueueID(0))
          actions.add QidAction(
            op:  HoldQid,
            qid: n.globalQid wrap - size + 1,
            xid: n.globalQid wrap)
          break

        actions.add QidAction(
          op:  HoldQid,
          qid: n.globalQid q[0],
          xid: n.globalQid wrap)
        size -= qSize0

        state[n] = (QueueID(0), QueueID(0))

  (actions, QidSchedRef(ctx: fifo.ctx, state: state))


func lengths*(
    fifo: QidSchedRef;                             # Cascaded fifos descriptor
      ): seq[int] =
  ## Return the list of lengths for all cascaded sub-fifos.
  for n in 0 ..< fifo.state.len:
    result.add fifo.state[n].fifoLen(fifo.ctx.q[n].wrap).int

func len*(
    fifo: QidSchedRef;                             # Cascaded fifos descriptor
      ): int =
  ## Size of the fifo
  fifo.lengths.foldl(a + b, 0)


func `[]`*(
    fifo: QidSchedRef;                             # Cascaded fifos descriptor
    inx: int;                                      # Index into latest items
      ): QueueID =
  ## Get the queue ID of the `inx`-th `fifo` entry where index `0` refers to
  ## the entry most recently added, `1` the one before, etc. If there is no
  ## such entry `QueueID(0)` is returned.
  if 0 <= inx:
    var inx = inx.uint64

    for n in 0 ..< fifo.state.len:
      let q = fifo.state[n]
      if q[0] == 0:
        discard

      elif q[0] <= q[1]:
        # Single file
        # ::
        #  |          :
        #  |  q[0]--> 3
        #  |          4
        #  |          5 <--q[1]
        #  |           :
        #
        let qInxMax = q[1] - q[0]
        if inx <= qInxMax:
          return n.globalQid(q[1] - inx)
        inx -= qInxMax + 1 # Otherwise continue

      else:
        # Wrap aound, double files
        # ::
        #  |          :
        #  |          3 <--q[1]
        #  |          4
        #  |  q[0]--> 5
        #  |          :
        #  |         wrap
        let qInxMax1 = q[1] - QueueID(1)
        if inx <= qInxMax1:
          return n.globalQid(q[1] - inx)
        inx -= qInxMax1 + 1 # Otherwise continue

        let
          wrap = fifo.ctx.q[n].wrap
          qInxMax0 = wrap - q[0]
        if inx <= qInxMax0:
          return n.globalQid(wrap - inx)
        inx -= qInxMax0 + 1 # Otherwise continue


func `[]`*(
    fifo: QidSchedRef;                             # Cascaded fifos descriptor
    qid: QueueID;                                  # Index into latest items
      ): int =
  ## ..
  if QueueID(0) < qid:
    let
      chn = (qid.uint64 shr 62).int
      qid = (qid.uint64 and 0x3fff_ffff_ffff_ffffu64).QueueID

    if chn < fifo.state.len:
      var offs = 0
      for n in 0 ..< chn:
        offs += fifo.state[n].fifoLen(fifo.ctx.q[n].wrap).int

      let q = fifo.state[chn]
      if q[0] <= q[1]:
        # Single file
        # ::
        #  |          :
        #  |  q[0]--> 3
        #  |          4
        #  |          5 <--q[1]
        #  |           :
        #
        if q[0] <= qid and qid <= q[1]:
          return offs + (q[1] - qid).int
      else:
        # Wrap aound, double files
        # ::
        #  |          :
        #  |          3 <--q[1]
        #  |          4
        #  |  q[0]--> 5
        #  |          :
        #  |         wrap
        #
        if QueueID(1) <= qid and qid <= q[1]:
          return offs + (q[1] - qid).int

        if q[0] <= qid:
          let wrap = fifo.ctx.q[chn].wrap
          if qid <= wrap:
            return offs + (q[1] - QueueID(0)).int + (wrap - qid).int
  -1


proc le*(
    fifo: QidSchedRef;                             # Cascaded fifos descriptor
    fid: FilterID;                                 # Upper bound
    fn: QuFilMap;                                  # QueueID/FilterID mapping
      ): QueueID =
  ## Find the `qid` address of type `QueueID` with
  ## * `fn(qid) <= fid`
  ## * for all `qid1` with `fn(qid1) <= fid` one has `fn(qid1) <= fn(qid)`
  ##
  ## If `fn()` returns `FilterID(0)`, then this function returns `QueueID(0)`
  ##
  ## The argument type `QuFilMap` of map `fn()` has been commented on earlier.
  ##
  var
    left = 0
    right = fifo.len - 1

  template getFid(qid: QueueID): FilterID =
    let fid = fn(qid)
    if not fid.isValid:
      return QueueID(0)
    fid

  if 0 <= right:
    let maxQid = fifo[left]
    if maxQid.getFid <= fid:
      return maxQid

    # Bisection
    if fifo[right].getFid <= fid:
      while 1 < right - left:
        let half = (left + right) div 2
        #
        # FilterID:   100      70       33
        # inx:        left ... half ... right
        # fid:             77
        #
        # with `fifo[left].fn > fid >= fifo[right].fn`
        #
        if fid >= fifo[half].getFid:
          right = half
        else: # fifo[half].getFid > fid
          left = half

      # Now: `fifo[right].fn <= fid < fifo[left].fn` (and `right == left+1`)
      return fifo[right]

  # otherwise QueueID(0)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
