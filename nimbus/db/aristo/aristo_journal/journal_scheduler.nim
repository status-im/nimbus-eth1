# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[algorithm, sequtils, typetraits],
  results,
  ".."/[aristo_constants, aristo_desc]

type
  QidAction* = object
    ## Instruction for administering filter queue ID slots. The op-code is
    ## followed by one or two queue ID arguments. In case of a two arguments,
    ## the value of the second queue ID is never smaller than the first one.
    op*: QidOp                     ## Action, followed by at most two queue IDs
    qid*: QueueID                  ## Action argument
    xid*: QueueID                  ## Second action argument for range argument

  QidOp* = enum
    Oops = 0
    SaveQid                        ## Store new item
    HoldQid                        ## Move/append range items to local queue
    DequQid                        ## Store merged local queue items
    DelQid                         ## Delete entry from last overflow queue

  QuFilMap* = proc(qid: QueueID): Result[FilterID,void] {.gcsafe, raises: [].}
    ## A map `fn: QueueID -> FilterID` of type `QuFilMap` must preserve the
    ## order relation on the image of `fn()` defined as
    ##
    ## * `fn(fifo[j]) < fn(fifo[i])` <=> `i < j`
    ##
    ## where `[]` is defined as the index function `[]: {0 .. N-1} -> QueueID`,
    ## `N = fifo.len`.
    ##
    ## Any injective function `fn()` (aka monomorphism) will do.
    ##
    ## This definition decouples access to ordered journal records from the
    ## storage of these records on the database. The records are accessed via
    ## `QueueID` type keys while the order is defined by a `FilterID` type
    ## scalar.
    ##
    ## In order to flag an error, `err()` must be returned.

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

func capacity(
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

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func capacity*(
    ctx: openArray[tuple[size, width, wrap: int]]; # Schedule layout
      ): tuple[maxQueue: int, minCovered: int, maxCovered: int] =
  ## Variant of `capacity()`.
  ctx.toSeq.mapIt((it[0],it[1])).capacity

func capacity*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
      ): tuple[maxQueue: int, minCovered: int, maxCovered: int] =
  ## Number of maximally stored and covered queued entries for the layout of
  ## argument `journal`. The resulting value of `maxQueue` entry is the maximal
  ## number of database slots needed, the `minCovered` and `maxCovered` entry
  ## indicate the rancge of the backlog foa a fully populated database.
  journal.ctx.q.toSeq.mapIt((it[0].int,it[1].int)).capacity()


func addItem*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
      ): tuple[exec: seq[QidAction], journal: QidSchedRef] =
  ## Get the instructions for adding a new slot to the cascades queues. The
  ## argument `journal` is a complete state of the addresses of a cascaded
  ## *FIFO* when applied to a database. Only the *FIFO* queue addresses are
  ## needed in order to describe how to add another item.
  ##
  ## The function returns a list of instructions what to do when adding a new
  ## item and the new state of the cascaded *FIFO*. The following instructions
  ## may be returned:
  ## ::
  ##    SaveQid <queue-id>         -- Store a new item under the address
  ##                               -- <queue-id> on the database.
  ##
  ##    HoldQid <from-id>..<to-id> -- Move the records referred to by the
  ##                               -- argument addresses from the database to
  ##                               -- the right end of the local hold queue.
  ##                               -- The age of the items on the hold queue
  ##                               -- increases left to right.
  ##
  ##    DequQid <queue-id>         -- Merge items from the hold queue into a
  ##                               -- new item and store it under the address
  ##                               -- <queue-id> on the database. Clear the
  ##                               -- the hold queue and the corresponding
  ##                               -- items on the database.
  ##
  ##    DelQid <queue-id>          -- Delete item. This happens if the last
  ##                               -- oberflow queue needs to make space for
  ##                               -- another item.
  ##
  let
    ctx = journal.ctx.q
  var
    state = journal.state
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

  (revActions.reversed, QidSchedRef(ctx: journal.ctx, state: state))


func fetchItems*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
    size: int;                                     # Leading items to merge
      ): tuple[exec: seq[QidAction], journal: QidSchedRef] =
  ## Get the instructions for extracting the latest `size` items from the
  ## cascaded queues. argument `journal` is a complete state of the addresses of
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
    state = journal.state

  if 0 < size:
    var size = size.uint64

    for n in 0 ..< journal.state.len:
      let q = journal.state[n]
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
          wrap = journal.ctx.q[n].wrap
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

  (actions, QidSchedRef(ctx: journal.ctx, state: state))


func lengths*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
      ): seq[int] =
  ## Return the list of lengths for all cascaded sub-fifos.
  for n in 0 ..< journal.state.len:
    result.add journal.state[n].fifoLen(journal.ctx.q[n].wrap).int

func len*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
      ): int =
  ## Size of the journal
  journal.lengths.foldl(a + b, 0)


func `[]`*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
    inx: int;                                      # Index into latest items
      ): QueueID =
  ## Get the queue ID of the `inx`-th `journal` entry where index `0` refers to
  ## the entry most recently added, `1` the one before, etc. If there is no
  ## such entry `QueueID(0)` is returned.
  if 0 <= inx:
    var inx = inx.uint64

    for n in 0 ..< journal.state.len:
      let q = journal.state[n]
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
          wrap = journal.ctx.q[n].wrap
          qInxMax0 = wrap - q[0]
        if inx <= qInxMax0:
          return n.globalQid(wrap - inx)
        inx -= qInxMax0 + 1 # Otherwise continue

func `[]`*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
    bix: BackwardsIndex;                           # Index into latest items
      ): QueueID =
  ## Variant of `[]` for providing `[^bix]`.
  journal[journal.len - bix.distinctBase]


func `[]`*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
    qid: QueueID;                                  # Index into latest items
      ): int =
  ## ..
  if QueueID(0) < qid:
    let
      chn = (qid.uint64 shr 62).int
      qid = (qid.uint64 and 0x3fff_ffff_ffff_ffffu64).QueueID

    if chn < journal.state.len:
      var offs = 0
      for n in 0 ..< chn:
        offs += journal.state[n].fifoLen(journal.ctx.q[n].wrap).int

      let q = journal.state[chn]
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
          let wrap = journal.ctx.q[chn].wrap
          if qid <= wrap:
            return offs + (q[1] - QueueID(0)).int + (wrap - qid).int
  -1


proc le*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
    fid: FilterID;                                 # Upper (or right) bound
    fn: QuFilMap;                                  # QueueID/FilterID mapping
    forceEQ = false;                               # Check for strict equality
      ): QueueID =
  ## Find the `qid` address of type `QueueID` with `fn(qid) <= fid` with
  ## maximal `fn(qid)`. The requirements on argument map `fn()` of type
  ## `QuFilMap` has been commented on at the type definition.
  ##
  ## This function returns `QueueID(0)` if `fn()` returns `err()` at some
  ## stage of the algorithm applied here.
  ##
  var
    left = 0
    right = journal.len - 1

  template toFid(qid: QueueID): FilterID =
    fn(qid).valueOr:
      return QueueID(0) # exit hosting function environment

  # The algorithm below trys to avoid `toFid()` as much as possible because
  # it might invoke some extra database lookup.

  if 0 <= right:
    # Check left fringe
    let
      maxQid = journal[left]
      maxFid = maxQid.toFid
    if maxFid <= fid:
      if forceEQ and maxFid != fid:
        return QueueID(0)
      return maxQid
    # So `fid < journal[left]`

    # Check right fringe
    let
      minQid = journal[right]
      minFid = minQid.toFid
    if fid <= minFid:
      if minFid == fid:
        return minQid
      return QueueID(0)
    # So `journal[right] < fid`

    # Bisection
    var rightQid = minQid                          # Might be used as end result
    while 1 < right - left:
      let
        pivot = (left + right) div 2
        pivQid = journal[pivot]
        pivFid = pivQid.toFid
      #
      # Example:
      # ::
      #   FilterID:   100       70       33
      #   inx:        left ... pivot ... right
      #   fid:             77
      #
      # with `journal[left].toFid > fid > journal[right].toFid`
      #
      if pivFid < fid:                             # fid >= journal[half].toFid:
        right = pivot
        rightQid = pivQid
      elif fid < pivFid:                           # journal[half].toFid > fid
        left = pivot
      else:
        return pivQid

    # Now: `journal[right].toFid < fid < journal[left].toFid`
    #      (and `right == left+1`).
    if not forceEQ:
      # Make sure that `journal[right].toFid` exists
      if fn(rightQid).isOk:
        return rightQid

  # Otherwise QueueID(0)


proc eq*(
    journal: QidSchedRef;                          # Cascaded fifos descriptor
    fid: FilterID;                                 # Filter ID to search for
    fn: QuFilMap;                                  # QueueID/FilterID mapping
      ): QueueID =
  ## Variant of `le()` for strict equality.
  journal.le(fid, fn, forceEQ = true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
