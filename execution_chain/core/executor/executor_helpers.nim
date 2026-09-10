# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
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
  ../../common/common,
  ../../transaction/call_types

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

func createBloom*(receipts: openArray[StoredReceipt]): Bloom =
  var bloom: LogsBloom
  for rec in receipts:
    bloom.value = bloom.value or logsBloom(rec.logs).value
  bloom.value.to(Bloom)

proc makeReceipt*(
    vmState: BaseVMState; txType: TxType, callResult: var LogResult): StoredReceipt =
  ## Builds the receipt for `callResult`, moving its log entries into the
  ## receipt and leaving `callResult.logEntries` empty.
  if vmState.com.isByzantiumOrLater(vmState.blockNumber, vmState.blockCtx.timestamp):
    result.isHash = false
    result.status = vmState.status
  else:
    result.isHash = true
    result.hash   = vmState.ledger.getStateRoot()
    # we set the status for the t8n output consistency
    result.status = vmState.status

  result.receiptType = txType
  result.cumulativeGasUsed = vmState.cumulativeGasUsed
  result.logs = move(callResult.logEntries)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
