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
  ../keequ/kq_debug,
  ./tx_info,
  ./tx_item,
  ./tx_tabs,
  chronos,
  eth/[common, keys],
  stew/results

type
  TxJobID* = ##\
    ## Valid interval: *1 .. TxJobIdMax*, the value `0` corresponds to\
    ## `TxJobIdMax` and is internally accepted only right after initialisation.
    distinct uint

  TxJobKind* = enum ##\
    ## Job types
    txJobNone = 0
    txJobAbort
    txJobAddTxs
    txJobApplyByLocal
    txJobApplyByRejected
    txJobApplyByStatus
    txJobEvictionInactive
    txJobFlushRejects
    txJobMoveRemoteToLocals
    txJobSetBaseFee
    txJobSetHead
    txJobUpdatePending
    txJobUpdateStaged

  TxJobItemApply* = ##\
    ## Generic item function used as apply function. If the function
    ## returns false, the apply loop is aborted
    ##
    ## :Note:
    ##   This function must not use the `async`, `await`, `waitFor`
    ##   directives. Synchronisation becomes unpredictable, otherwise.
    proc(item: TxItemRef): bool {.gcsafe,raises: [Defect].}

  TxJobDataRef* = ref object
    case kind*: TxJobKind
    of txJobNone: ##\
      ## no action
      discard

    of txJobAbort: ##\
      ## Stop processing and flush job queue
      ##
      ## Out-of-band job (runs with priority)
      discard

    of txJobAddTxs: ##\
      ## Enqueues a batch of transactions into the pool if they are valid,
      ## marking the senders as `local` or `remote` ones depending on
      ## the request arguments.
      addTxsArgs*: tuple[
        txs:   seq[Transaction],
        local: bool,
        info:  string]

    of txJobApplyByLocal: ##\
      ## Apply argument function to all `local` or `remote` items.
      ##
      ## :Note:
      ##    It is OK to request the current item to be moved to the waste
      ##    basket.
      applyByLocalArgs*: tuple[
        local: bool,
        apply: TxJobItemApply]

    of txJobApplyByStatus: ##\
      ## Apply argument function to all `status` items.
      ##
      ## :Note:
      ##    It is OK to request the current item to be moved to the waste
      ##    basket.
      applyByStatusArgs*: tuple[
        status: TxItemStatus,
        apply:  TxJobItemApply]

    of txJobApplyByRejected: ##\
      ## Apply argument function to all `rejected` items.
      applyByRejectedArgs*: tuple[
        apply:  TxJobItemApply]

    of txJobEvictionInactive: ##\
      ## Move transactions older than `xp.lifeTime` to the waste basket.
      discard

    of txJobFlushRejects: ##\
      ## Deletes at most the `maxItems` oldest items from the waste basket.
      ##
      ## Out-of-band job (runs with priority)
      flushRejectsArgs*: tuple[
        maxItems: int]

    of txJobMoveRemoteToLocals: ##\
      ## For given account, remote transactions are migrated to local
      ## transactions.
      moveRemoteToLocalsArgs*: tuple[
        account: EthAddress]

    of txJobSetBaseFee: ##\
      ## New base fee (implies database reorg). Note that after changing the
      ## `baseFee`, most probably a re-org should take place (e.g. invoking
      ## `txJobUpdatePending`)
      setBaseFeeArgs*: tuple[
        price: GasPrice]

    of txJobSetHead: ##\
      ## Change the insertion block header. This call might imply
      ## re-calculating current transaction states.
      setHeadArgs*: tuple[
        head:  Hash256]

    of txJobUpdatePending: ##\
      ## For all items, re-calculate `queued` and `pending` status. If the
      ## `force` flag is set, re-calculation is done even though the change
      ## flag hes remained unset.
      updatePendingArgs*: tuple[
        force: bool]

    of txJobUpdateStaged: ##\
      ## Smartly collect `pending` items and label them `staged`. If the
      ## `force` flag is set, re-calculation is done even though the change
      ## flag hes remained unset.
      updateStagedArgs*: tuple[
        force: bool]

  TxJobPair* = object
    id*: TxJobID
    data*: TxJobDataRef

  TxJobRef* = ref object ##\
    ## Job queue with increasing job *ID* numbers (wrapping around at
    ## `TxJobIdMax`.)
    topID: TxJobID                        ## Next job will have `topID+1`
    jobQueue: KeeQu[TxJobID,TxJobDataRef] ## Job queue
    eventQueue: KeeQu[TxJobID,AsyncEvent] ## Can wait for some jobs

const
  txJobPriorityKind*: set[TxJobKind] = ##\
    ## Prioritised jobs, either small or important ones (as re-org)
    {txJobAbort,
      txJobFlushRejects}

  txJobIdMax* = ##\
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
  ##   An error can only occur if
  ##   the *ID* of the first job follows the *ID* of the last job (*modulo*
  ##   `TxJobIdMax`.) This occurs when
  ##   * there are `TxJobIdMax` jobs already queued
  ##   * some jobs were deleted in the middle of the queue and the *ID*
  ##     gap was not shifted out yet.
  var id: TxJobID
  if txJobIdMax <= jq.topID:
    id = 1.TxJobID
  else:
    id = jq.topID + 1
  if jq.jobQueue.append(id, data):
    jq.topID = id
    return id

proc jobUnshift(jq: TxJobRef; data: TxJobDataRef): TxJobID
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Stores *back* a job to to the *FIFO* front end be re-fetched next. This
  ## function returns a non-zero *ID* if successful.
  ##
  ## See also the **Note* at the comment for `txAdd()`.
  var id: TxJobID
  if jq.jobQueue.len == 0:
    if jq.topID == 0.TxJobID:
      jq.topID = txJobIdMax # must be non-zero after first use
    id = jq.topID
  else:
    id = jq.jobQueue.firstKey.value - 1
    if id == 0.TxJobID:
      id = txJobIdMax
  if jq.jobQueue.unshift(id, data):
    return id

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxJobRef; initSize = 10): T =
  ## Constructor variant
  new result
  result.jobQueue.init(initSize)
  result.eventQueue.init(1)

proc clear*(jq: TxJobRef) =
  ## Re-initilaise variant
  jq.jobQueue.clear
  jq.eventQueue.clear

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

proc isWaitedFor*(jq: TxJobRef; id: TxJobID): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Returns true if somebody waits for the job to have finished.
  jq.eventQueue.hasKey(id)

proc waitLatest*(jq: TxJobRef) {.async.} =
  ## Wait for the currently latest job to have finished.
  let rc = jq.eventQueue.lastKey
  if rc.isErr:
    return # nothing to wait for

  # wait for the latest job ID to have finished
  let id = rc.value

  # event not in table yet?
  if not jq.eventQueue.hasKey(id):
    jq.eventQueue[id] = newAsyncEvent()

    # fire immediately if this is the only one
    if jq.eventQueue.len == 1:
      jq.eventQueue[id].fire
      return

  # wait until event has fired
  await jq.eventQueue[id].wait


proc fetch*(jq: TxJobRef): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Fetches (and deletes) the next job from the *FIFO*.
  var kvp: TxJobPair

  # first item from queue
  block:
    let rc = jq.jobQueue.shift
    if rc.isErr:
      return err()
    kvp.id = rc.value.key
    kvp.data = rc.value.data

  # process event queue as follows:
  #
  #   on the event queue do for the job `kvp.id` of the current event
  #
  #   * if the first event has key `kvp.id`
  #     => remove the first event
  #     => fire the next event on the queue (if any)
  #
  block:
    # check whether this is the first item, if so => trigger next
    let rc1st = jq.eventQueue.first
    if rc1st.isOK and rc1st.value.key == kvp.id:

      jq.eventQueue.del(kvp.id) # not needed anymore
      let rc2nd = jq.eventQueue.first
      if rc2nd.isOK:
        rc2nd.value.data.fire

  ok(kvp)

proc dispose*(jq: TxJobRef; id: TxJobID) {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete or disable the job with the job ID passed as argument `id`. If the
  ## job is the next in the *FIFO*, then it will be deleted as with `fetch()`
  ## while ignoring the return value. Otherwise the job will be re-classified
  ## as `txJobNone` while leaving it on the *FIFO* queue.
  ##
  ## The effect is that if priority jobs have been pushed before the current
  ## one, they will be fetched and processed up until the current job is
  ## re-visited, again. Eventually, this job becomes the next in the *FIFO*
  ## and will be deleted as with `fetch()`.
  ##
  ## This handling is necessary for `waitLatest()` event signalling which must
  ## not trigger before the related batch of jobs has fully been cleared.
  ##
  # check first item
  let rc = jq.jobQueue.first
  if rc.isOk:
    if id == rc.value.key:
      # just remove that item (this will update event triggers)
      discard jq.fetch
    else:
      # re-pupose as idle job and leave it on the queue so it will probably be
      # visited again and properly discarded
      jq.jobQueue[id] = TxJobDataRef(kind: txJobNone)


proc first*(jq: TxJobRef): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Peek, get the next due job (like `fetch()`) but leave it in the
  ## queue (unlike `fetch()`).
  let rc = jq.jobQueue.first
  if rc.isErr:
    return err()
  ok(TxJobPair(id: rc.value.key, data: rc.value.data))

# ------------------------------------------------------------------------------
# Public queue/table ops
# ------------------------------------------------------------------------------

proc`[]`*(jq: TxJobRef; id: TxJobID): TxJobDataRef
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  jq.jobQueue[id]

proc hasKey*(jq: TxJobRef; id: TxJobID): bool
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  jq.jobQueue.hasKey(id)

proc len*(jq: TxJobRef): int
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  jq.jobQueue.len

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(jq: TxJobRef): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,KeyError].} =
  block:
    let rc = jq.jobQueue.verify
    if rc.isErr:
      return err(txInfoVfyJobQueue)

  block:
    var isFired = true
    for kvp in jq.eventQueue.nextPairs:
      if not jq.jobQueue.hasKey(kvp.key):
        return err(txInfoVfyJobEvent)
      # first id must have been fired and the other reset
      if kvp.data.isSet != isFired:
        return err(txInfoVfyJobEvent)
      isFired = false

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
