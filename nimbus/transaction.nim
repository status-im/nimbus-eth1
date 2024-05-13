# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[sequtils, typetraits],
  ./constants, ./errors, eth/[common, keys], ./utils/utils,
  common/evmforks, ./vm_gas_costs

import eth/common/transaction as common_transaction
export common_transaction, errors

proc toWordSize(size: GasInt): GasInt =
  # Round input to the nearest bigger multiple of 32
  # tx validation will ensure the value is not too big
  if size > GasInt.high-31:
    return (GasInt.high shr 5) + 1

  (size + 31) shr 5

func intrinsicGas*(data: openArray[byte], fork: EVMFork): GasInt =
  result = gasFees[fork][GasTransaction]
  for i in data:
    if i == 0:
      result += gasFees[fork][GasTXDataZero]
    else:
      result += gasFees[fork][GasTXDataNonZero]

proc intrinsicGas*(tx: Transaction, fork: EVMFork): GasInt =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation)
  result = distinctBase(tx.payload.input).intrinsicGas(fork)

  if tx.contractCreation:
    result = result + gasFees[fork][GasTXCreate]
    if fork >= FkShanghai:
      # cannot use wordCount here, it will raise unlisted exception
      let numWords = toWordSize(tx.payload.input.len)
      result = result + (gasFees[fork][GasInitcodeWord] * numWords)

  if tx.payload.access_list.isSome:
    template access_list: untyped = tx.payload.access_list.unsafeGet
    result = result + access_list.len * ACCESS_LIST_ADDRESS_COST
    var numKeys = 0
    for n in access_list:
      inc(numKeys, n.storage_keys.len)
    result = result + numKeys * ACCESS_LIST_STORAGE_KEY_COST

proc getSignature*(tx: Transaction, output: var Signature): bool =
  let sig = Signature.fromRaw(tx.signature.ecdsa_signature)
  if sig.isOk:
    output = sig[]
    return true
  return false

proc toSignature*(tx: Transaction): Signature =
  if not getSignature(tx, result):
    raise newException(Exception, "Invalid signature")

proc getSender*(tx: Transaction, output: var EthAddress): bool =
  ## Find the address the transaction was sent from.
  output = tx.signature.from_address
  true

proc getSender*(tx: Transaction): EthAddress =
  ## Raises error on failure to recover public key
  if not tx.getSender(result):
    raise newException(ValidationError, "Could not derive sender address from transaction")

proc getRecipient*(tx: Transaction, sender: EthAddress): EthAddress =
  if tx.contractCreation:
    result = generateAddress(sender, tx.payload.nonce)
  else:
    result = tx.payload.to.get()

proc validate*(tx: Transaction, fork: EVMFork, chainId: ChainId) =
  # parameters pass validation rules
  if tx.intrinsicGas(fork).uint64 > tx.payload.gas:
    raise newException(ValidationError, "Insufficient gas")

  if fork >= FkShanghai and tx.contractCreation and
       tx.payload.input.len > EIP3860_MAX_INITCODE_SIZE:
    raise newException(ValidationError, "Initcode size exceeds max")

  if tx.payload.blob_versioned_hashes.isSome:
    template vhs: untyped = tx.payload.blob_versioned_hashes.unsafeGet
    if vhs.len > MAX_BLOBS_PER_BLOCK:
      raise newException(ValidationError, "Too many blob versioned hashes")
    if not vhs.allIt(it.data[0] == VERSIONED_HASH_VERSION_KZG):
      raise newException(ValidationError, "Invalid blob versioned hash")

  # check signature validity
  let anyTx = AnyTransaction.fromOneOfBase(tx).valueOr:
    raise newException(ValidationError, "Invalid combination of fields")
  withTxVariant(anyTx):
    if txVariant.validate_transaction(chainId).isErr:
      raise newException(ValidationError,
        "Invalid signature or failed message verification")
