# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  constants, errors, eth_common, eth_keys, rlp

proc intrinsicGas*(t: Transaction): GasInt =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation)
  raise newException(ValueError, "not implemented intrinsicGas")

proc validate*(t: Transaction) =
  # Hook called during instantiation to ensure that all transaction
  # parameters pass validation rules
  if t.intrinsicGas() > t.gasLimit:
    raise newException(ValidationError, "Insufficient gas")
  #  self.check_signature_validity()

func hash*(transaction: Transaction): Hash256 =
  # Hash transaction without signature
  type
    TransHashObj = object
      accountNonce:  AccountNonce
      gasPrice:      GasInt
      gasLimit:      GasInt
      to:            EthAddress
      value:         UInt256
      payload:       Blob
  return TransHashObj(
    accountNonce: transaction.accountNonce,
    gasPrice: transaction.gasPrice,
    gasLimit: transaction.gasLimit,
    to: transaction.to,
    value: transaction.value,
    payload: transaction.payload
    ).rlpHash

proc toSignature*(transaction: Transaction): Signature =
  var bytes: array[65, byte]
  bytes[0..31] = transaction.R.toByteArrayBE()
  bytes[32..63] = transaction.S.toByteArrayBE()
  # TODO: V will become a byte or range soon.
  bytes[64] = transaction.V
  initSignature(bytes)

proc getSender*(transaction: Transaction, output: var EthAddress): bool =
  ## Find the address the transaction was sent from.
  let
    txHash = transaction.hash # hash without signature
    sig = transaction.toSignature()
  var pubKey: PublicKey
  if recoverSignatureKey(sig, txHash.data, pubKey) == EthKeysStatus.Success:
    output = pubKey.toCanonicalAddress()
    result = true

proc getSender*(transaction: Transaction): EthAddress =
  ## Raises error on failure to recover public key
  if not transaction.getSender(result):
    raise newException(ValidationError, "Could not derive sender address from transaction")
