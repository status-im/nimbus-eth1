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
  ./tx_info,
  ./tx_item,
  ./tx_tabs,
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
    txJobItemSetStatus
    txJobMoveRemoteToLocals
    txJobRejectItem
    txJobSetBaseFee
    txJobSetGasPrice
    txJobSetHead
    txJobUpdatePending

  TxJobItemApply* = ##\
    ## Generic item function used as apply function. If the function
    ## returns false, the apply loop is aborted
    proc(item: TxItemRef): bool {.gcsafe,raises: [Defect].}


  TxJobDataRef* = ref object
    hiatus*: bool ##\
      ## Suspend the job queue and return current results.

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

    of txJobItemSetStatus: ##\
      ## Set/update status for particular item.
      itemSetStatusArgs*: tuple[
        item:   TxItemRef,
        status: TxItemStatus]

    of txJobMoveRemoteToLocals: ##\
      ## For given account, remote transactions are migrated to local
      ## transactions.
      moveRemoteToLocalsArgs*: tuple[
        account: EthAddress]

    of txJobRejectItem: ##\
      ## Move argument `item` to waste basket
      rejectItemArgs*: tuple[
        item:   TxItemRef,
        reason: TxInfo]

    of txJobSetBaseFee: ##\
      ## New base fee (implies database reorg). Note that after changing the
      ## `baseFee`, most probably a re-org should take place (e.g. invoking
      ## `txJobUpdatePending`)
      setBaseFeeArgs*: tuple[
        price: uint64]

    of txJobSetGasPrice: ##\
      ## Set the minimum price required by the transaction pool for a new
      ## transaction.  Increasing it will move all transactions below this
      ## threshold to the waste basket.
      setGasPriceArgs*: tuple[
        price: uint64]

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


  TxJobPair* = object
    id*: TxJobID
    data*: TxJobDataRef

  TxJob* = object ##\
    ## Job queue with increasing job *ID* numbers (wrapping around at
    ## `TxJobIdMax`.)
    topID: TxJobID                        ## Next job will have `topID+1`
    jobQueue: KeeQu[TxJobID,TxJobDataRef] ## Job queue

const
  txJobPriorityKind*: set[TxJobKind] = ##\
    ## Prioritised jobs, either small or important ones (as re-org)
    {txJobAbort,
      txJobFlushRejects,
      txJobRejectItem}

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

proc jobAppend(t: var TxJob; data: TxJobDataRef): TxJobID
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
  if txJobIdMax <= t.topID:
    id = 1.TxJobID
  else:
    id = t.topID + 1
  if t.jobQueue.append(id, data):
    t.topID = id
    return id

proc jobUnshift(t: var TxJob; data: TxJobDataRef): TxJobID
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Stores *back* a job to to the *FIFO* front end be re-fetched next. This
  ## function returns a non-zero *ID* if successful.
  ##
  ## See also the **Note* at the comment for `txAdd()`.
  var id: TxJobID
  if t.jobQueue.len == 0:
    if t.topID == 0.TxJobID:
      t.topID = txJobIdMax # must be non-zero after first use
    id = t.topID
  else:
    id = t.jobQueue.firstKey.value - 1
    if id == 0.TxJobID:
      id = txJobIdMax
  if t.jobQueue.unshift(id, data):
    return id

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(t: var TxJob; initSize = 10) =
  ## Optional constructor
  t.jobQueue.init(initSize)

proc init*(T: type TxJob; initSize = 10): T =
  ## Constructor variant
  result.init(initSize)

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc add*(t: var TxJob; data: TxJobDataRef): TxJobID
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Add a new job to the *FIFO*.
  if data.kind in txJobPriorityKind:
    result = t.jobUnshift(data)
  else:
    result = t.jobAppend(data)

proc delete*(t: var TxJob; id: TxJobID): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Delete a job by argument `id`. The function returns the job just
  ## deleted (if successful.)
  ##
  ## See also the **Note* at the comment for `txAdd()`.
  let rc = t.jobQueue.delete(id)
  if rc.isErr:
    result = err()
  else:
    result = ok(TxJobPair(id: rc.value.key, data: rc.value.data))

proc fetch*(t: var TxJob): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Fetches the next job from the *FIFO*.
  let rc = t.jobQueue.shift
  if rc.isErr:
    result = err()
  else:
    result = ok(TxJobPair(id: rc.value.key, data: rc.value.data))

proc first*(t: var TxJob): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Peek, get the next due job (like `fetch()`) but leave it in the
  ## queue (unlike `fetch()`).
  let rc = t.jobQueue.first
  if rc.isErr:
    result = err()
  else:
    result = ok(TxJobPair(id: rc.value.key, data: rc.value.data))

# ------------------------------------------------------------------------------
# Public queue/table ops
# ------------------------------------------------------------------------------

proc`[]`*(t: var TxJob; id: TxJobID): TxJobDataRef
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  result = t.jobQueue[id]

proc hasKey*(t: var TxJob; id: TxJobID): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  result = t.jobQueue.hasKey(id)

proc len*(t: var TxJob): int
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  result = t.jobQueue.len

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(t: var TxJob): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = t.jobQueue.verify
  if rc.isErr:
    return err(txInfoVfyJobQueue)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
