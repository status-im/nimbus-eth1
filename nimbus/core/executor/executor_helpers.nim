# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/bloom,
  ../../db/ledger,
  ../../evm/state,
  ../../evm/types,
  ../../common/common

type
  ExecutorError* = object of CatchableError
    ## Catch and relay exception error

  # TODO: these types need to be removed
  # once eth/bloom and eth/common sync'ed
  LogsBloom = bloom.BloomFilter

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func logsBloom(logs: openArray[Log]): LogsBloom =
  for log in logs:
    result.incl log.address
    for topic in log.topics:
      result.incl topic

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func createBloom*(receipts: openArray[Receipt]): Bloom =
  var bloom: LogsBloom
  for rec in receipts:
    bloom.value = bloom.value or logsBloom(rec.logs).value
  bloom.value.to(Bloom)

proc makeReceipt*(vmState: BaseVMState; txType: TxType): Receipt =

  var rec: Receipt
  if vmState.com.isByzantiumOrLater(vmState.blockNumber):
    rec.isHash = false
    rec.status = vmState.status
  else:
    rec.isHash = true
    rec.hash   = vmState.stateDB.getStateRoot()
    # we set the status for the t8n output consistency
    rec.status = vmState.status

  rec.receiptType = txType
  rec.cumulativeGasUsed = vmState.cumulativeGasUsed
  rec.logs = vmState.getAndClearLogEntries()
  rec.logsBloom = logsBloom(rec.logs).value.to(Bloom)
  rec

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
