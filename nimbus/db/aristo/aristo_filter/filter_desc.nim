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
  ../aristo_desc

type
  StateRootPair* = object
    ## Helper structure for analysing state roots.
    be*: HashKey                   ## Backend state root
    fg*: HashKey                   ## Layer or filter implied state root

  # ----------------

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

  QidLayoutRef* = ref object
    ## Layout of cascaded list of filter ID slot queues where a slot queue
    ## with index `N+1` serves as an overflow queue of slot queue `N`.
    q*: array[4,QidSpec]

  QidSpec* = tuple
    ## Layout of a filter ID slot queue
    size: uint                     ## Capacity of queue, length within `1..wrap`
    width: uint                    ## Instance gaps (relative to prev. item)
    wrap: QueueID                  ## Range `1..wrap` for round-robin queue

  QidSchedRef* = ref object of RootRef
    ## Current state of the filter queues
    ctx*: QidLayoutRef             ## Organisation of the FIFO
    state*: seq[(QueueID,QueueID)] ## Current fill state

const
  DefaultQidWrap = QueueID(0x3fff_ffff_ffff_ffffu64)

  QidSpecSizeMax* = high(uint32).uint
    ## Maximum value allowed for a `size` value of a `QidSpec` object

  QidSpecWidthMax* = high(uint32).uint
    ## Maximum value allowed for a `width` value of a `QidSpec` object

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func max(a, b, c: int): int =
  max(max(a,b),c)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func to*(a: array[4,tuple[size, width: int]]; T: type QidLayoutRef): T =
  ## Convert a size-width array to a `QidLayoutRef` layout. Over large
  ## array field values are adjusted to its maximal size.
  var q: array[4,QidSpec]
  for n in 0..3:
    q[n] = (min(a[n].size.uint, QidSpecSizeMax),
            min(a[n].width.uint, QidSpecWidthMax),
            DefaultQidWrap)
  q[0].width = 0
  T(q: q)

func to*(a: array[4,tuple[size, width, wrap: int]]; T: type QidLayoutRef): T =
  ## Convert a size-width-wrap array to a `QidLayoutRef` layout. Over large
  ## array field values are adjusted to its maximal size. Too small `wrap`
  ## values are adjusted to its minimal size.
  var q: array[4,QidSpec]
  for n in 0..2:
    q[n] = (min(a[n].size.uint, QidSpecSizeMax),
            min(a[n].width.uint, QidSpecWidthMax),
            QueueID(max(a[n].size + a[n+1].width, a[n].width+1, a[n].wrap)))
  q[0].width = 0
  q[3] = (min(a[3].size.uint, QidSpecSizeMax),
          min(a[3].width.uint, QidSpecWidthMax),
          QueueID(max(a[3].size, a[3].width, a[3].wrap)))
  T(q: q)

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

func init*(T: type QidSchedRef; a: array[4,(int,int)]): T =
  ## Constructor, see comments at the coverter function `to()` for adjustments
  ## of the layout argument `a`.
  T(ctx: a.to(QidLayoutRef))

func init*(T: type QidSchedRef; a: array[4,(int,int,int)]): T =
  ## Constructor, see comments at the coverter function `to()` for adjustments
  ## of the layout argument `a`.
  T(ctx: a.to(QidLayoutRef))

func init*(T: type QidSchedRef; ctx: QidLayoutRef): T =
  T(ctx: ctx)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
