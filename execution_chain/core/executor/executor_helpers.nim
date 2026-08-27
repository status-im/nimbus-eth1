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
  ../../db/ledger,
  ../../evm/state,
  ../../evm/types,
  ../../common/common,
  ../../transaction/call_types

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func incl(acc: var Bloom, b: Bloom) {.inline.} =
  for i in 0 ..< acc.data.len:
    acc.data[i] = acc.data[i] or b.data[i]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func createBloom*(receipts: openArray[StoredReceipt]): Bloom =
  for rec in receipts:
    result.accumLogsBloom(rec.logs)

func createBloom*(blooms: openArray[Bloom], bloom: var Bloom) =
  var acc: Bloom
  for b in blooms:
    acc.incl b
  bloom = acc

proc makeReceipt*(
    vmState: BaseVMState; txType: TxType): StoredReceipt =
  if txType == TxEip8141:
    result.receiptType = txType
    result.cumulativeGasUsed = vmState.cumulativeGasUsed
    result.payer = vmState.payer().get()
    result.frameReceipts = move(vmState.frameCtx.snapshot.receipts)
    # txLogs are appended to blockLogs.
    # although txLogs are not consumed here, we set it to zero to match
    # the behavior of other transaction types
    vmState.txLogs.setLen(0)
  else:
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
    result.logs = move(vmState.txLogs)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
