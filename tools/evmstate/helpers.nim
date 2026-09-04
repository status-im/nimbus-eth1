# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common/[base, keys, headers, transactions, receipts],
  stew/byteutils,
  json_serialization,
  ../../execution_chain/transaction,
  ../../execution_chain/db/ledger,
  ../../execution_chain/common/chain_config,
  ./parser

export
  parser

template required(res, n: untyped): auto =
  if n.isSome:
    res = n.value
  else:
    return err(astToStr(n) & " field missing")

template required(res, n: untyped, i: int): auto =
  if i >= n.len:
    return err("index out of range")
  res = n[i]

template optional(res, n: untyped) =
  res = n

template defaultZero(res, n: untyped) =
  if n.isSome:
    res = n.value
  else:
    res = default(typeof(res))

template defaultZero(res, n: untyped, i: int) =
  if n.isSome:
    res = n.value[i]
  else:
    res = default(typeof(res))

func txType(n: Txo): TxType =
  if n.authorizationList.isSome:
    return TxEip7702
  if n.blobVersionedHashes.isSome:
    return TxEip4844
  if n.gasPrice.isNone:
    return TxEip1559
  if n.accessLists.isSome:
    return TxEip2930
  TxLegacy

func parseHeader*(n: StateEnv): Result[Header, string] =
  var res = Header(
    stateRoot: emptyRoot
  )
  required(res.coinbase, n.currentCoinbase)
  required(res.difficulty, n.currentDifficulty)
  required(res.number, n.currentNumber)
  required(res.gasLimit, n.currentGasLimit)
  required(res.timestamp, n.currentTimestamp)

  defaultZero(res.mixHash, n.currentRandom)
  optional(res.baseFeePerGas, n.currentBaseFee)
  optional(res.withdrawalsRoot, n.currentWithdrawalsRoot)
  optional(res.excessBlobGas, n.currentExcessBlobGas)
  optional(res.parentBeaconBlockRoot, n.currentBeaconRoot)
  optional(res.slotNumber, n.slotNumber)
  ok(move(res))

func parseParentHeader*(n: StateEnv): Result[Header, string] =
  var res = Header(
    stateRoot: emptyRoot
  )
  required(res.number, n.currentNumber)
  dec res.number
  optional(res.excessBlobGas, n.parentExcessBlobGas)
  optional(res.blobGasUsed, n.parentBlobGasUsed)
  ok(move(res))

func parseTx*(n: Txo, index: Index): Result[Transaction, string] =
  var tx = Transaction(
    txType  : txType(n)
  )
  required(tx.nonce, n.nonce)
  required(tx.gasLimit, n.gasLimit, index.gas)
  required(tx.value, n.value, index.value)
  required(tx.payload, n.data, index.data)
  defaultZero(tx.chainId, n.chainId)
  defaultZero(tx.gasPrice, n.gasPrice)
  defaultZero(tx.maxFeePerGas, n.maxFeePerGas)
  defaultZero(tx.accessList, n.accessLists, index.data)
  defaultZero(tx.maxPriorityFeePerGas, n.maxPriorityFeePerGas)
  defaultZero(tx.maxFeePerBlobGas, n.maxFeePerBlobGas)
  defaultZero(tx.versionedHashes, n.blobVersionedHashes)
  defaultZero(tx.authorizationList, n.authorizationList)

  try:
    if n.to != "":
      tx.to = Opt.some(Address.fromHex(n.to))
  except ValueError as exc:
    return err("Field 'to' error: " & exc.msg)

  let secretKey = n.secretKey.valueOr:
    return err("missing secretKey field")
  ok(signTransaction(tx, secretKey, n.chainId.isSome))

func parseReceipt*(rec: TxoReceipt): Receipt =
  if rec.postState.isSome:
    Receipt(
      receiptType      : ReceiptType(rec.`type`),
      isHash           : true,
      hash             : rec.postState.value,
      cumulativeGasUsed: rec.cumulativeGasUsed,
      logsBloom        : rec.bloom.value.to(Bloom),
      logs             : rec.logs,
    )
  else:
    Receipt(
      receiptType      : ReceiptType(rec.`type`),
      isHash           : false,
      status           : rec.status.get,
      cumulativeGasUsed: rec.cumulativeGasUsed,
      logsBloom        : rec.bloom.value.to(Bloom),
      logs             : rec.logs,
    )

proc setupLedger*(wantedState: GenesisAlloc, ledger: LedgerRef) =
  for address, account in wantedState:
    for slot, value in account.storage:
      ledger.setStorage(address, slot, value)

    ledger.setNonce(address, account.nonce)
    ledger.setCode(address, account.code)
    ledger.setBalance(address, account.balance)

proc parseFixture*(jsonFile: string): Result[StateFixture, string] =
  try:
    ok(Fixture.loadFile(jsonFile, StateFixture))
  except SerializationError as exc:
    err((ref JsonReaderError)(exc).formatMsg(""))
  except IOError as exc:
    err(exc.msg)
