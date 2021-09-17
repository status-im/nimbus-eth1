# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Jobs Queue For Transaction Pool
## ===============================
##

import
  std/[hashes, tables],
   ../keequ,
  eth/[common, keys],
  stew/results

type
  TxJobsInfo* = enum
    txJobsOk = 0
    txJobsVfyQueue ## Corrupted ID queue/fifo structure

  TxJobID* = ##\
    ## Valid interval: *1 .. TxJobIdMax*, the value `0` corresponds to\
    ## `TxJobIdMax` and is internally accepted only right after initialisation.
    distinct uint

  TxJobKind* = enum
    txJobNone = 0
    txJobChainHeadEvent
    txJobsShutDown
    txJobsStatsReport
    txJobsInactiveJobsEviction
    txJobsJocalTxJournalRotation

  TxJobData* = object
    case kind*: TxJobKind
    of txJobNone:
      discard
    of txJobChainHeadEvent:
      oldHeader*: BlockHeader
      newHeader*: BlockHeader
    of txJobsShutDown:
      discard
    of txJobsStatsReport:
      discard
    of txJobsInactiveJobsEviction:
      discard
    of txJobsJocalTxJournalRotation:
      discard

  TxJobPair* = object
    id*: TxJobID
    data*: TxJobData

  TxJobs* = object ##\
    ## Job queue with increasing job *ID* numbers (wrapping around at
    ## `TxJobIdMax`.)
    topID: TxJobID              ## Next job to append will have `topID+1`
    jobQueue: KeeQu[TxJobID,TxJobData] ## Job queue

const
  TxJobIdMax* = ##\
    ## Wraps around to `1` after last ID
    999999.TxJobID

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(id: TxJobID): Hash =
  ## Needed if `TxJobID` is used as hash-`Table` index.
  id.uint.hash

proc `+`(a, b: TxJobID): TxJobID {.borrow.}
proc `-`(a, b: TxJobID): TxJobID {.borrow.}

proc `+`(a: TxJobID; b: int): TxJobID = a + b.TxJobID
proc `-`(a: TxJobID; b: int): TxJobID = a - b.TxJobID

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc `<=`*(a, b: TxJobID): bool {.borrow.}
proc `==`*(a, b: TxJobID): bool {.borrow.}

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(t: var TxJobs; initSize = 10) =
  ## Optional constructor
  t.jobQueue.init(initSize)

proc init*(T: type TxJobs; initSize = 10): T =
  ## Constructor variant
  result.init(initSize)

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc add*(t: var TxJobs; data: TxJobData): TxJobID
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Appends a job to the *FIFO*. This function returns a non-zero *ID* if
  ## successful.
  ##
  ## :Note:
  ##   An error can only occur if
  ##   the *ID* of the first job follows the *ID* of the last job (*modulo*
  ##   `TxJobIdMax`.) This occurs when
  ##   * there are `TxJobIdMax` jobs already queued
  ##   * some jobs were deleted in the middle of the queue and the *ID*
  ##     gap was not shifted out yet.
  var id: TxJobID
  if TxJobIdMax <= t.topID:
    id = 1.TxJobID
  else:
    id = t.topID + 1
  if t.jobQueue.append(id, data):
    t.topID = id
    return id

proc unshift*(t: var TxJobs; data: TxJobData): TxJobID
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Stores *back* a job to to the *FIFO* front end be re-fetched next. This
  ## function returns a non-zero *ID* if successful.
  ##
  ## See also the **Note* at the comment for `txAdd()`.
  var id: TxJobID
  if t.jobQueue.len == 0:
    if t.topID == 0.TxJobID:
      t.topID = TxJobIdMax # must be non-zero after first use
    id = t.topID
  else:
    id = t.jobQueue.firstKey.value - 1
    if id == 0.TxJobID:
      id = TxJobIdMax
  if t.jobQueue.unshift(id, data):
    return id


proc delete*(t: var TxJobs; id: TxJobID): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete a job by argument `id`. The function returns the job just
  ## deleted (if successful.)
  ##
  ## See also the **Note* at the comment for `txAdd()`.
  let rc = t.jobQueue.delete(id)
  if rc.isErr:
    return err()
  ok(TxJobPair(id: rc.value.key, data: rc.value.data))

proc shift*(t: var TxJobs): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Fetches the next job from the *FIFO*. This is logically the same
  ## as `txFirst()` followed by `txDelete()`
  let rc = t.jobQueue.shift
  if rc.isErr:
    return err()
  ok(TxJobPair(id: rc.value.key, data: rc.value.data))

# ------------------------------------------------------------------------------
# Public fetch & traversal
# ------------------------------------------------------------------------------

proc first*(t: var TxJobs): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = t.jobQueue.first
  if rc.isErr:
    return err()
  ok(TxJobPair(id: rc.value.key, data: rc.value.data))

# ------------------------------------------------------------------------------
# Public queue/table ops
# ------------------------------------------------------------------------------

proc`[]`*(t: var TxJobs; id: TxJobID): TxJobData
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  t.jobQueue[id]

proc hasKey*(t: var TxJobs; id: TxJobID): bool {.inline.} =
  t.jobQueue.hasKey(id)

proc len*(t: var TxJobs): int {.inline.} =
  t.jobQueue.len

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(t: var TxJobs): Result[void,(TxJobsInfo,KeeQuInfo)]
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = t.jobQueue.verify
  if rc.isErr:
    return err((txJobsVfyQueue,rc.error[2]))
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
