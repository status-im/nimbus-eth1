# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./constants, ./errors, eth/[common, keys], ./utils,
  ./forks, ./vm_gas_costs

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

  if tx.contractCreation:
    result = result + gasFees[fork][GasTXCreate]

  if tx.txType > TxLegacy:
    result = result + tx.accessList.len * ACCESS_LIST_ADDRESS_COST
    var numKeys = 0
    for n in tx.accessList:
      inc(numKeys, n.storageKeys.len)
    result = result + numKeys * ACCESS_LIST_STORAGE_KEY_COST

proc getSignature*(tx: Transaction, output: var Signature): bool =
  var bytes: array[65, byte]
  bytes[0..31] = tx.R.toByteArrayBE()
  bytes[32..63] = tx.S.toByteArrayBE()

  if tx.txType == TxLegacy:
    var v = tx.V
    if v >= EIP155_CHAIN_ID_OFFSET:
      v = 28 - (v and 0x01)
    elif v == 27 or v == 28:
      discard
    else:
      return false
    bytes[64] = byte(v - 27)
  else:
    bytes[64] = tx.V.byte

  let sig = Signature.fromRaw(bytes)
  if sig.isOk:
    output = sig[]
    return true
  return false

proc toSignature*(tx: Transaction): Signature =
  if not getSignature(tx, result):
    raise newException(Exception, "Invalid signature")

proc getSender*(tx: Transaction, output: var EthAddress): bool =
  ## Find the address the transaction was sent from.
  var sig: Signature
  if tx.getSignature(sig):
    var txHash = tx.txHashNoSignature
    let pubkey = recover(sig, SkMessage(txHash.data))
    if pubkey.isOk:
      output = pubkey[].toCanonicalAddress()
      result = true

proc getSender*(tx: Transaction): EthAddress =
  ## Raises error on failure to recover public key
  if not tx.getSender(result):
    raise newException(ValidationError, "Could not derive sender address from transaction")

proc getRecipient*(tx: Transaction, sender: EthAddress): EthAddress =
  if tx.contractCreation:
    result = generateAddress(sender, tx.nonce)
  else:
    result = tx.to.get()

proc validateTxLegacy(tx: Transaction, fork: Fork) =
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

proc validateTxEip2930(tx: Transaction) =
  var isValid = tx.V in {0'i64, 1'i64}
  isValid = isValid and tx.S >= Uint256.one
  isValid = isValid and tx.S < SECPK1_N
  isValid = isValid and tx.R < SECPK1_N

  if not isValid:
    raise newException(ValidationError, "Invalid transaction")

proc validate*(tx: Transaction, fork: Fork) =
  # parameters pass validation rules
  if tx.intrinsicGas(fork) > tx.gasLimit:
    raise newException(ValidationError, "Insufficient gas")

  # check signature validity
  var sender: EthAddress
  if not tx.getSender(sender):
    raise newException(ValidationError, "Invalid signature or failed message verification")

  case tx.txType
  of TxLegacy:
    validateTxLegacy(tx, fork)
  else:
    validateTxEip2930(tx)

proc signTransaction*(tx: Transaction, privateKey: PrivateKey, chainId: ChainId, eip155: bool): Transaction =
  result = tx
  if eip155:
    # trigger rlpEncodeEIP155 in nim-eth
    result.V = chainId.int64 * 2'i64 + 35'i64

  let
    rlpTx = rlpEncode(result)
    sig = sign(privateKey, rlpTx).toRaw

  case tx.txType
  of TxLegacy:
    if eip155:
      result.V = sig[64].int64 + result.V
    else:
      result.V = sig[64].int64 + 27'i64
  else:
    result.V = sig[64].int64

  result.R = Uint256.fromBytesBE(sig[0..31])
  result.S = Uint256.fromBytesBE(sig[32..63])
