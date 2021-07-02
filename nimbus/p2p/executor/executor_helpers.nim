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
  ../../db/accounts_cache,
  ../../forks,
  ../../vm_state,
  ../../vm_types,
  eth/[common, bloom]

type
  # TODO: these types need to be removed
  # once eth/bloom and eth/common sync'ed
  Bloom = common.BloomFilter
  LogsBloom = bloom.BloomFilter

# TODO: move these three receipt procs below somewhere else more appropriate
func logsBloom(logs: openArray[Log]): LogsBloom =
  for log in logs:
    result.incl log.address
    for topic in log.topics:
      result.incl topic

func createBloom*(receipts: openArray[Receipt]): Bloom =
  var bloom: LogsBloom
  for rec in receipts:
    bloom.value = bloom.value or logsBloom(rec.logs).value
  result = bloom.value.toByteArrayBE

proc makeReceipt*(vmState: BaseVMState, fork: Fork, txType: TxType): Receipt =
  var rec: Receipt
  if fork < FkByzantium:
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

# End
