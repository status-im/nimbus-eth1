# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./constants, ./errors, eth/[common, keys], ./utils,
  stew/shims/macros,
  ./vm_types2, ./vm_gas_costs

import eth/common/transaction as common_transaction
export common_transaction

template txc(fn: untyped, params: varargs[untyped]): untyped =
  if tx.txType == LegacyTxType:
    unpackArgs(fn, [tx.legacyTx, params])
  else:
    unpackArgs(fn, [tx.accessListTx, params])

template txField(field: untyped): untyped =
  if tx.txType == LegacyTxType:
    tx.legacyTx.field
  else:
    tx.accessListTx.field

template txFieldAsgn(field, data: untyped) =
  if tx.txType == LegacyTxType:
    tx.legacyTx.field = data
  else:
    tx.accessListTx.field = data

template recField(field: untyped): untyped =
  if rec.receiptType == LegacyReceiptType:
    rec.legacyReceipt.field
  else:
    rec.accessListReceipt.field

func intrinsicGas*(data: openarray[byte], fork: Fork): GasInt =
  result = gasFees[fork][GasTransaction]
  for i in data:
    if i == 0:
      result += gasFees[fork][GasTXDataZero]
    else:
      result += gasFees[fork][GasTXDataNonZero]

proc intrinsicGas*(tx: TxTypes, fork: Fork): GasInt =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation)
  result = tx.payload.intrinsicGas(fork)

  if tx.isContractCreation:
    result = result + gasFees[fork][GasTXCreate]

proc intrinsicGas*(tx: Transaction, fork: Fork): GasInt =
  txc(intrinsicGas, fork)

proc getSignature*(tx: LegacyTx, output: var Signature): bool =
  var bytes: array[65, byte]
  bytes[0..31] = tx.R.toByteArrayBE()
  bytes[32..63] = tx.S.toByteArrayBE()

  # TODO: V will become a byte or range soon.
  var v = tx.V
  if v >= EIP155_CHAIN_ID_OFFSET:
    v = 28 - (v and 0x01)
  elif v == 27 or v == 28:
    discard
  else:
    return false

  bytes[64] = byte(v - 27)
  let sig = Signature.fromRaw(bytes)
  if sig.isOk:
    output = sig[]
    return true
  return false

proc getSignature*(tx: AccessListTx, output: var Signature): bool =
  var bytes: array[65, byte]
  bytes[0..31] = tx.R.toByteArrayBE()
  bytes[32..63] = tx.S.toByteArrayBE()
  bytes[64] = tx.V.byte
  let sig = Signature.fromRaw(bytes)
  if sig.isOk:
    output = sig[]
    return true
  return false

proc getSignature*(tx: Transaction, output: var Signature): bool =
  txc(getSignature, output)

proc toSignature*(tx: Transaction): Signature =
  if not getSignature(tx, result):
    raise newException(Exception, "Invalid signature")

proc getSender*(tx: LegacyTx | AccessListTx | Transaction, output: var EthAddress): bool =
  ## Find the address the transaction was sent from.
  var sig: Signature
  if tx.getSignature(sig):
    var txHash = tx.txHashNoSignature
    let pubkey = recover(sig, SkMessage(txHash.data))
    if pubkey.isOk:
      output = pubkey[].toCanonicalAddress()
      result = true

proc getSender*(tx: LegacyTx | AccessListTx | Transaction): EthAddress =
  ## Raises error on failure to recover public key
  if not tx.getSender(result):
    raise newException(ValidationError, "Could not derive sender address from transaction")

proc getRecipient*(tx: LegacyTx | AccessListTx, sender: EthAddress): EthAddress =
  if tx.isContractCreation:
    result = generateAddress(sender, tx.nonce)
  else:
    result = tx.to

proc getRecipient*(tx: Transaction, sender: EthAddress): EthAddress =
  txc(getRecipient, sender)

proc gasLimit*(tx: Transaction): GasInt =
  txField(gasLimit)

proc gasPrice*(tx: Transaction): GasInt =
  txField(gasPrice)

proc value*(tx: Transaction): UInt256 =
  txField(value)

proc isContractCreation*(tx: Transaction): bool =
  txField(isContractCreation)

proc to*(tx: Transaction): EthAddress =
  txField(to)

proc payload*(tx: Transaction): Blob =
  txField(payload)

proc nonce*(tx: Transaction): AccountNonce =
  txField(nonce)

proc V*(tx: Transaction): int64 =
  txField(V)

proc R*(tx: Transaction): UInt256 =
  txField(R)

proc S*(tx: Transaction): UInt256 =
  txField(S)

proc `payload=`*(tx: var Transaction, data: Blob) =
  txFieldAsgn(payload, data)

proc `gasLimit=`*(tx: var Transaction, data: GasInt) =
  txFieldAsgn(gasLimit, data)

proc cumulativeGasUsed*(rec: Receipt): GasInt =
  recField(cumulativeGasUsed)

proc logs*(rec: Receipt): auto =
  recField(logs)

proc bloom*(rec: Receipt): auto =
  recField(bloom)

proc hasStateRoot*(rec: Receipt): bool =
  if rec.receiptType == LegacyReceiptType:
    rec.legacyReceipt.hasStateRoot
  else:
    false

proc hasStatus*(rec: Receipt): bool =
  if rec.receiptType == LegacyReceiptType:
    rec.legacyReceipt.hasStatus
  else:
    true

proc status*(rec: Receipt): int =
  if rec.receiptType == LegacyReceiptType:
    rec.legacyReceipt.status
  else:
    rec.accessListReceipt.status.int

proc stateRoot*(rec: Receipt): Hash256 =
  if rec.receiptType == LegacyReceiptType:
    return rec.legacyReceipt.stateRoot

proc validate*(tx: LegacyTx, fork: Fork) =
  # Hook called during instantiation to ensure that all transaction
  # parameters pass validation rules
  if tx.intrinsicGas(fork) > tx.gasLimit:
    raise newException(ValidationError, "Insufficient gas")

  # check signature validity
  var sender: EthAddress
  if not tx.getSender(sender):
    raise newException(ValidationError, "Invalid signature or failed message verification")

  var
    vMin = 27'i64
    vMax = 28'i64

  if tx.V >= EIP155_CHAIN_ID_OFFSET:
    let chainId = (tx.V - EIP155_CHAIN_ID_OFFSET) div 2
    vMin = 35 + (2 * chainId)
    vMax = vMin + 1

  var isValid = tx.R >= Uint256.one
  isValid = isValid and tx.S >= Uint256.one
  isValid = isValid and tx.V >= vMin
  isValid = isValid and tx.V <= vMax
  isValid = isValid and tx.S < SECPK1_N
  isValid = isValid and tx.R < SECPK1_N

  if fork >= FkHomestead:
    isValid = isValid and tx.S < SECPK1_N div 2

  if not isValid:
    raise newException(ValidationError, "Invalid transaction")
