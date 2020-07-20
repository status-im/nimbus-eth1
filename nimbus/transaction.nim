# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  constants, errors, eth/[common, keys], utils,
  ./vm/interpreter/[vm_forks, gas_costs], constants

import eth/common/transaction as common_transaction
export common_transaction

func intrinsicGas*(data: openarray[byte], fork: Fork): GasInt =
  result = gasFees[fork][GasTransaction]
  for i in data:
    if i == 0:
      result += gasFees[fork][GasTXDataZero]
    else:
      result += gasFees[fork][GasTXDataNonZero]

proc intrinsicGas*(tx: Transaction, fork: Fork): GasInt =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation)
  result = tx.payload.intrinsicGas(fork)

  if tx.isContractCreation:
    result = result + gasFees[fork][GasTXCreate]

proc getSignature*(transaction: Transaction, output: var Signature): bool =
  var bytes: array[65, byte]
  bytes[0..31] = transaction.R.toByteArrayBE()
  bytes[32..63] = transaction.S.toByteArrayBE()

  # TODO: V will become a byte or range soon.
  var v = transaction.V.int
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

proc toSignature*(transaction: Transaction): Signature =
  if not getSignature(transaction, result):
    raise newException(Exception, "Invalid signature")

proc getSender*(transaction: Transaction, output: var EthAddress): bool =
  ## Find the address the transaction was sent from.
  var sig: Signature
  if transaction.getSignature(sig):
    var txHash = transaction.txHashNoSignature
    let pubkey = recover(sig, SkMessage(txHash.data))
    if pubkey.isOk:
      output = pubkey[].toCanonicalAddress()
      result = true

proc getSender*(transaction: Transaction): EthAddress =
  ## Raises error on failure to recover public key
  if not transaction.getSender(result):
    raise newException(ValidationError, "Could not derive sender address from transaction")

proc getRecipient*(tx: Transaction): EthAddress =
  if tx.isContractCreation:
    let sender = tx.getSender()
    result = generateAddress(sender, tx.accountNonce)
  else:
    result = tx.to

proc validate*(tx: Transaction, fork: Fork) =
  # Hook called during instantiation to ensure that all transaction
  # parameters pass validation rules
  if tx.intrinsicGas(fork) > tx.gasLimit:
    raise newException(ValidationError, "Insufficient gas")

  # check signature validity
  var sender: EthAddress
  if not tx.getSender(sender):
    raise newException(ValidationError, "Invalid signature or failed message verification")

  var
    vMin = 27
    vMax = 28

  if tx.V.int >= EIP155_CHAIN_ID_OFFSET:
    let chainId = (tx.V.int - EIP155_CHAIN_ID_OFFSET) div 2
    vMin = 35 + (2 * chainId)
    vMax = vMin + 1

  var isValid = tx.R >= Uint256.one
  isValid = isValid and tx.S >= Uint256.one
  isValid = isValid and tx.V.int >= vMin
  isValid = isValid and tx.V.int <= vMax
  isValid = isValid and tx.S < SECPK1_N
  isValid = isValid and tx.R < SECPK1_N

  if fork >= FkHomestead:
    isValid = isValid and tx.S < SECPK1_N div 2

  if not isValid:
    raise newException(ValidationError, "Invalid transaction")

