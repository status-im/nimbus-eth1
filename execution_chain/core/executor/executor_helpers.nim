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

type
  ExecutorError* = object of CatchableError
    ## Catch and relay exception error

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func incl(acc: var Bloom, b: Bloom) =
  for i in 0 ..< acc.data.len:
    acc.data[i] = acc.data[i] or b.data[i]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func createBloom*(receipts: openArray[StoredReceipt]): Bloom =
  for rec in receipts:
    result.incl calcLogsBloom(rec.logs)

func createBloom*(blooms: openArray[Bloom]): Bloom =
  for b in blooms:
    result.incl b

proc makeReceipt*(
    vmState: BaseVMState; txType: TxType): StoredReceipt =
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
