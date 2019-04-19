# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  constants, errors, eth/[common, rlp, keys], nimcrypto, utils

proc initTransaction*(nonce: AccountNonce, gasPrice, gasLimit: GasInt, to: EthAddress,
  value: UInt256, payload: Blob, V: byte, R, S: UInt256, isContractCreation = false): Transaction =
  result.accountNonce = nonce
  result.gasPrice = gasPrice
  result.gasLimit = gasLimit
  result.to = to
  result.value = value
  result.payload = payload
  result.V = V
  result.R = R
  result.S = S
  result.isContractCreation = isContractCreation

func intrinsicGas*(data: openarray[byte]): GasInt =
  result = 21_000   # GasTransaction
  for i in data:
    if i == 0:
      result += 4   # GasTXDataZero
    else:
      result += 68  # GasTXDataNonZero

proc intrinsicGas*(t: Transaction): GasInt =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation)
  result = t.payload.intrinsicGas

proc validate*(t: Transaction) =
  # Hook called during instantiation to ensure that all transaction
  # parameters pass validation rules
  if t.intrinsicGas() > t.gasLimit:
    raise newException(ValidationError, "Insufficient gas")
  #  self.check_signature_validity()

type
  TransHashObj = object
    accountNonce:  AccountNonce
    gasPrice:      GasInt
    gasLimit:      GasInt
    to {.rlpCustomSerialization.}: EthAddress
    value:         UInt256
    payload:       Blob
    mIsContractCreation {.rlpIgnore.}: bool

proc read(rlp: var Rlp, t: var TransHashObj, _: type EthAddress): EthAddress {.inline.} =
  if rlp.blobLen != 0:
    result = rlp.read(EthAddress)
  else:
    t.mIsContractCreation = true

proc append(rlpWriter: var RlpWriter, t: TransHashObj, a: EthAddress) {.inline.} =
  if t.mIsContractCreation:
    rlpWriter.append("")
  else:
    rlpWriter.append(a)

const
  EIP155_CHAIN_ID_OFFSET = 35

func rlpEncode*(transaction: Transaction): auto =
  # Encode transaction without signature
  return rlp.encode(TransHashObj(
    accountNonce: transaction.accountNonce,
    gasPrice: transaction.gasPrice,
    gasLimit: transaction.gasLimit,
    to: transaction.to,
    value: transaction.value,
    payload: transaction.payload,
    mIsContractCreation: transaction.isContractCreation
    ))

func rlpEncodeEIP155*(tx: Transaction): auto =
  let V = (tx.V.int - EIP155_CHAIN_ID_OFFSET) div 2
  # Encode transaction without signature
  return rlp.encode(Transaction(
    accountNonce: tx.accountNonce,
    gasPrice: tx.gasPrice,
    gasLimit: tx.gasLimit,
    to: tx.to,
    value: tx.value,
    payload: tx.payload,
    isContractCreation: tx.isContractCreation,
    V: V.byte,
    R: 0.u256,
    S: 0.u256
    ))

func txHashNoSignature*(tx: Transaction): Hash256 =
  # Hash transaction without signature
  return keccak256.digest(if tx.V.int >= EIP155_CHAIN_ID_OFFSET: tx.rlpEncodeEIP155 else: tx.rlpEncode)

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
  result = recoverSignature(bytes, output) == EthKeysStatus.Success

proc toSignature*(transaction: Transaction): Signature =
  if not getSignature(transaction, result):
    raise newException(Exception, "Invalid signaure")

proc getSender*(transaction: Transaction, output: var EthAddress): bool =
  ## Find the address the transaction was sent from.
  var sig: Signature
  if transaction.getSignature(sig):
    var pubKey: PublicKey
    var txHash = transaction.txHashNoSignature
    if recoverSignatureKey(sig, txHash.data, pubKey) == EthKeysStatus.Success:
      output = pubKey.toCanonicalAddress()
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
