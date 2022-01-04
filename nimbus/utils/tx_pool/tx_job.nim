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
  ./tx_info,
  ./tx_item,
  ./tx_tabs,
  eth/[common, keys],
  stew/[keyed_queue, keyed_queue/kq_debug, results]

{.push raises: [Defect].}

# hide complexity unless really needed
const
  jobWaitCompilerFlag = defined(job_wait_enabled) or defined(debug)

  JobWaitEnabled* =  ##\
    ## Compiler flag: fire *chronos* event if job queue becomes populated
    jobWaitCompilerFlag

when JobWaitEnabled:
  import chronos


type
  TxJobID* = ##\
    ## Valid interval: *1 .. TxJobIdMax*, the value `0` corresponds to\
    ## `TxJobIdMax` and is internally accepted only right after initialisation.
    distinct uint

  TxJobKind* = enum ##\
    ## Types of batch job data. See `txJobPriorityKind` for the list of\
    ## *out-of-band* jobs.

    txJobNone = 0 ##\
      ## no action

    txJobAddTxs ##\
      ## Enqueues a batch of transactions

    txJobDelItemIDs ##\
      ## Enqueues a batch of itemIDs the items of which to be disposed

const
  txJobPriorityKind*: set[TxJobKind] = ##\
    ## Prioritised jobs, either small or important ones.
    {}

type
  TxJobDataRef* = ref object
    case kind*: TxJobKind
    of txJobNone:
      discard

    of txJobAddTxs:
      addTxsArgs*: tuple[
        txs:   seq[Transaction],
        info:  string]

    of txJobDelItemIDs:
      delItemIDsArgs*: tuple[
        itemIDs: seq[Hash256],
        reason:  TxInfo]


  TxJobPair* = object     ## Responding to a job queue query
    id*: TxJobID          ## Job ID, queue database key
    data*: TxJobDataRef   ## Data record


  TxJobRef* = ref object ##\
    ## Job queue with increasing job *ID* numbers (wrapping around at\
    ## `TxJobIdMax`.)
    topID: TxJobID                         ## Next job will have `topID+1`
    jobs: KeyedQueue[TxJobID,TxJobDataRef] ## Job queue

    # hide complexity unless really needed
    when JobWaitEnabled:
      jobsAvail: AsyncEvent                ## Fired if there is a job available

const
  txJobIdMax* = ##\
    ## Wraps around to `1` after last ID
    999999.TxJobID

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
# Public helpers (operators needed in jobAppend() and jobUnshift() functions)
# ------------------------------------------------------------------------------

proc `<=`*(a, b: TxJobID): bool {.borrow.}
proc `==`*(a, b: TxJobID): bool {.borrow.}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc jobAppend(jq: TxJobRef; data: TxJobDataRef): TxJobID
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Appends a job to the *FIFO*. This function returns a non-zero *ID* if
  ## successful.
  ##
  ## :Note:
  ##   An error can only occur if the *ID* of the first job follows the *ID*
  ##   of the last job (*modulo* `TxJobIdMax`). This occurs when
  ##   * there are `TxJobIdMax` jobs already on the queue
  ##   * some jobs were deleted in the middle of the queue and the *ID*
  ##     gap was not shifted out yet.
  var id: TxJobID
  if txJobIdMax <= jq.topID:
    id = 1.TxJobID
  else:
    id = jq.topID + 1
  if jq.jobs.append(id, data):
    jq.topID = id
    return id

proc jobUnshift(jq: TxJobRef; data: TxJobDataRef): TxJobID
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Stores *back* a job to to the *FIFO* front end be re-fetched next. This
  ## function returns a non-zero *ID* if successful.
  ##
  ## See also the **Note* at the comment for `txAdd()`.
  var id: TxJobID
  if jq.jobs.len == 0:
    if jq.topID == 0.TxJobID:
      jq.topID = txJobIdMax # must be non-zero after first use
    id = jq.topID
  else:
    id = jq.jobs.firstKey.value - 1
    if id == 0.TxJobID:
      id = txJobIdMax
  if jq.jobs.unshift(id, data):
    return id

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc new*(T: type TxJobRef; initSize = 10): T =
  ## Constructor variant
  new result
  result.jobs.init(initSize)

  # hide complexity unless really needed
  when JobWaitEnabled:
    result.jobsAvail = newAsyncEvent()


proc clear*(jq: TxJobRef) =
  ## Re-initilaise variant
  jq.jobs.clear

  # hide complexity unless really needed
  when JobWaitEnabled:
    jq.jobsAvail.clear

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc add*(jq: TxJobRef; data: TxJobDataRef): TxJobID
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add a new job to the *FIFO*.
  if data.kind in txJobPriorityKind:
    result = jq.jobUnshift(data)
  else:
    result = jq.jobAppend(data)

  # hide complexity unless really needed
  when JobWaitEnabled:
    # update event
    jq.jobsAvail.fire


proc fetch*(jq: TxJobRef): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Fetches (and deletes) the next job from the *FIFO*.

  # first item from queue
  let rc = jq.jobs.shift
  if rc.isErr:
    return err()

  # hide complexity unless really needed
  when JobWaitEnabled:
    # update event
    jq.jobsAvail.clear

  # result
  ok(TxJobPair(id: rc.value.key, data: rc.value.data))


# hide complexity unless really needed
when JobWaitEnabled:
  proc waitAvail*(jq: TxJobRef) {.async,raises: [Defect,CatchableError].} =
    ## Asynchronously wait until at least one job is available (available
    ## only if the `JobWaitEnabled` compile time constant is set.)
    if jq.jobs.len == 0:
      await jq.jobsAvail.wait
else:
  proc waitAvail*(jq: TxJobRef)
    {.deprecated: "will raise exception unless JobWaitEnabled is set",
      raises: [Defect,CatchableError].} =
    raiseAssert "Must not be called unless JobWaitEnabled is set"

# ------------------------------------------------------------------------------
# Public queue/table ops
# ------------------------------------------------------------------------------

proc`[]`*(jq: TxJobRef; id: TxJobID): TxJobDataRef
    {.gcsafe,raises: [Defect,KeyError].} =
  jq.jobs[id]

proc hasKey*(jq: TxJobRef; id: TxJobID): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  jq.jobs.hasKey(id)

proc len*(jq: TxJobRef): int
    {.gcsafe,raises: [Defect,KeyError].} =
  jq.jobs.len

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(jq: TxJobRef): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,KeyError].} =
  block:
    let rc = jq.jobs.verify
    if rc.isErr:
      return err(txInfoVfyJobQueue)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
