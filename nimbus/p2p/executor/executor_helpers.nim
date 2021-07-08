# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[strformat],
  ../../config,
  ../../db/accounts_cache,
  ../../forks,
  ../../vm_state,
  ../../vm_types,
  eth/[common, bloom]

type
  ExecutorError* = object of CatchableError
    ## Catch and relay exception error

  # TODO: these types need to be removed
  # once eth/bloom and eth/common sync'ed
  Bloom = common.BloomFilter
  LogsBloom = bloom.BloomFilter

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# TODO: move these three receipt procs below somewhere else more appropriate
func logsBloom(logs: openArray[Log]): LogsBloom =
  for log in logs:
    result.incl log.address
    for topic in log.topics:
      result.incl topic

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template safeExecutor*(info: string; code: untyped) =
  try:
    code
  except CatchableError as e:
    raise (ref CatchableError)(msg: e.msg)
  except Defect as e:
    raise (ref Defect)(msg: e.msg)
  except:
    let e = getCurrentException()
    raise newException(ExecutorError, info & "(): " & $e.name & " -- " & e.msg)

func createBloom*(receipts: openArray[Receipt]): Bloom =
  var bloom: LogsBloom
  for rec in receipts:
    bloom.value = bloom.value or logsBloom(rec.logs).value
  result = bloom.value.toByteArrayBE

proc getForkUnsafe*(vmState: BaseVMState): Fork
                       {.inline, raises: [Exception].} =
  ## Shortcut for configured fork, deliberately not naming it toFork(). This
  ## function may throw an `Exception` and must be wrapped.
  vmState.chainDB.config.toFork(vmState.blockNumber)

proc makeReceipt*(vmState: BaseVMState; txType: TxType): Receipt
                    {.inline, raises: [Defect,CatchableError].} =

  proc getFork(vmState: BaseVMState): Fork
               {.inline, raises: [Defect,CatchableError].} =
    safeExecutor("getFork"):
      result = vmState.getForkUnsafe

  var rec: Receipt
  if vmState.getFork < FkByzantium:
    rec.isHash = true
    rec.hash   = vmState.accountDb.rootHash
  else:
    rec.isHash = false
    rec.status = vmState.status

  rec.receiptType = txType
  rec.cumulativeGasUsed = vmState.cumulativeGasUsed
  rec.logs = vmState.getAndClearLogEntries()
  rec.bloom = logsBloom(rec.logs).value.toByteArrayBE
  rec

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
