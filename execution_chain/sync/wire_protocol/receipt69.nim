# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  eth/common/[addresses_rlp, base_rlp, hashes_rlp, receipts],
  eth/[rlp, bloom]

from stew/objects import checkedEnumAssign

type
  Receipt69* = object
    recType*      : ReceiptType
    isHash*       : bool          # hash or status
    status*       : bool          # EIP-658
    hash*         : Hash32
    cumulativeGas*: GasInt
    logs*         : seq[Log]

  Receipts69Packet* = object
    receipts*: seq[seq[Receipt69]]

proc append*(w: var RlpWriter, rec: Receipt69) =
  w.startList(4)
  w.append(rec.recType.uint)

  if rec.isHash:
    w.append(rec.hash)
  else:
    w.append(rec.status.uint8)

  w.append(rec.cumulativeGas)
  w.append(rec.logs)

proc read*(rlp: var Rlp, receipt: var Receipt69) {.raises: [RlpError].} =
  rlp.tryEnterList()
  let recType = rlp.read(uint8)
  var recVal: ReceiptType
  if checkedEnumAssign(recVal, recType):
    receipt.recType = recVal
  else:
    raise newException(UnsupportedRlpError, "Unsupported ReceiptType: " & $recType)

  if rlp.isBlob and rlp.blobLen in {0, 1}:
    receipt.isHash = false
    receipt.status = rlp.read(uint8) == 1
  elif rlp.isBlob and rlp.blobLen == 32:
    receipt.isHash = true
    receipt.hash = rlp.read(Hash32)
  else:
    raise newException(
      RlpTypeMismatch,
      "HashOrStatus expected, but the source RLP is not a blob of right size.",
    )

  rlp.read(receipt.cumulativeGas)
  rlp.read(receipt.logs)

func logsBloom(logs: openArray[Log]): bloom.BloomFilter =
  for log in logs:
    result.incl log.address
    for topic in log.topics:
      result.incl topic

func to(rec: Receipt69, _: type Receipt): Receipt =
  Receipt(
    receiptType: rec.recType,
    isHash: rec.isHash,
    status: rec.status,
    hash: rec.hash,
    cumulativeGasUsed: rec.cumulativeGas,
    logs: rec.logs,
    logsBloom: logsBloom(rec.logs).value.to(Bloom),
  )

func to(rec: Receipt, _: type Receipt69): Receipt69 =
  Receipt69(
    recType: rec.receiptType,
    isHash: rec.isHash,
    status: rec.status,
    hash: rec.hash,
    cumulativeGas: rec.cumulativeGasUsed,
    logs: rec.logs
  )

func to*(list: openArray[Receipt69], _: type seq[Receipt]): seq[Receipt] =
  for x in list:
    result.add x.to(Receipt)

func to*(list: openArray[Receipt], _: type seq[Receipt69]): seq[Receipt69] =
  for x in list:
    result.add x.to(Receipt69)
