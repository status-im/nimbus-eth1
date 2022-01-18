# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
## Recover Address From Signature
## ==============================
##
## This module provides caching and direct versions for recovering the
## `EthAddress` from an extended signature. The caching version reduces
## calculation time for the price of maintaing it in a LRU cache.

import
  ../constants,
  ./keyed_queue/kq_rlp,
  ./utils_defs,
  eth/[common, common/transaction, keys, rlp],
  nimcrypto,
  stew/[keyed_queue, results],
  stint

export
  utils_defs

{.push raises: [Defect].}

const
  INMEMORY_SIGNATURES* = ##\
    ## Default number of recent block signatures to keep in memory
    4096

type
  EcKey* = ##\
    ## Internal key used for the LRU cache (derived from Hash256).
    array[32,byte]

  EcAddrResult* = ##\
    ## Typical `EthAddress` result as returned by `ecRecover()` functions.
    Result[EthAddress,UtilsError]

  EcRecover* = object
    size: uint
    q: KeyedQueue[EcKey,EthAddress]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc vrsSerialised(tx: Transaction): Result[array[65,byte],UtilsError] =
  ## Parts copied from `transaction.getSignature`.
  var data: array[65,byte]
  data[0..31] = tx.R.toByteArrayBE
  data[32..63] = tx.S.toByteArrayBE

  if tx.txType != TxLegacy:
    data[64] = tx.V.byte
  elif tx.V >= EIP155_CHAIN_ID_OFFSET:
    data[64] = byte(1 - (tx.V and 1))
  elif tx.V == 27 or tx.V == 28:
    data[64] = byte(tx.V - 27)
  else:
    return err((errSigPrefixError,"")) # legacy error

  ok(data)

proc encodePreSealed(header: BlockHeader): seq[byte] =
  ## Cut sigature off `extraData` header field.
  if header.extraData.len < EXTRA_SEAL:
    return rlp.encode(header)

  var rlpHeader = header
  rlpHeader.extraData.setLen(header.extraData.len - EXTRA_SEAL)
  rlp.encode(rlpHeader)

proc hashPreSealed(header: BlockHeader): Hash256 =
  ## Returns the hash of a block prior to it being sealed.
  keccak256.digest header.encodePreSealed


proc recoverImpl(rawSig: openArray[byte]; msg: Hash256): EcAddrResult =
  ## Extract account address from the last 65 bytes of the `extraData` argument
  ## (which is typically the bock header field with the same name.) The second
  ## argument `hash` is used to extract the intermediate public key. Typically,
  ## this would be the hash of the block header without the last 65 bytes of
  ## the `extraData` field reserved for the signature.
  if rawSig.len < EXTRA_SEAL:
    return err((errMissingSignature,""))

  let sig = Signature.fromRaw(
    rawSig.toOpenArray(rawSig.len - EXTRA_SEAL, rawSig.high))
  if sig.isErr:
    return err((errSkSigResult,$sig.error))

  # Recover the public key from signature and seal hash
  let pubKey = recover(sig.value, SKMessage(msg.data))
  if pubKey.isErr:
    return err((errSkPubKeyResult,$pubKey.error))

  # Convert public key to address.
  ok(pubKey.value.toCanonicalAddress)

# ------------------------------------------------------------------------------
# Public function: straight ecRecover versions
# ------------------------------------------------------------------------------

proc ecRecover*(header: BlockHeader): EcAddrResult =
  ## Extracts account address from the `extraData` field (last 65 bytes) of
  ## the argument header.
  header.extraData.recoverImpl(header.hashPreSealed)

proc ecRecover*(tx: var Transaction): EcAddrResult =
  ## Extracts sender address from transaction. This function has similar
  ## functionality as `transaction.getSender()`.
  let txSig = tx.vrsSerialised
  if txSig.isErr:
    return err(txSig.error)
  txSig.value.recoverImpl(tx.txHashNoSignature)

proc ecRecover*(tx: Transaction): EcAddrResult =
  ## Variant of `ecRecover()` for call-by-value header.
  var ty = tx
  ty.ecRecover

# ------------------------------------------------------------------------------
# Public constructor for caching ecRecover version
# ------------------------------------------------------------------------------

proc init*(er: var EcRecover; cacheSize = INMEMORY_SIGNATURES; initSize = 10) =
  ## Inialise recover cache
  er.size = cacheSize.uint
  er.q.init(initSize)

proc init*(T: type EcRecover;
           cacheSize = INMEMORY_SIGNATURES; initSize = 10): T =
  ## Inialise recover cache
  result.init(cacheSize, initSize)

# ------------------------------------------------------------------------------
# Public functions: miscellaneous
# ------------------------------------------------------------------------------

proc len*(er: var EcRecover): int =
  ## Returns the current number of entries in the LRU cache.
  er.q.len

# ------------------------------------------------------------------------------
# Public functions: caching ecRecover version
# ------------------------------------------------------------------------------

proc ecRecover*(er: var EcRecover; header: var BlockHeader): EcAddrResult
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Extract account address from `extraData` field (last 65 bytes) of the
  ## argument header. The result is kept in a LRU cache to re-purposed for
  ## improved result delivery avoiding calculations.
  let key = header.blockHash.data
  block:
    let rc = er.q.lruFetch(key)
    if rc.isOK:
      return ok(rc.value)
  block:
    let rc = header.extraData.recoverImpl(header.hashPreSealed)
    if rc.isOK:
      return ok(er.q.lruAppend(key, rc.value, er.size.int))
    err(rc.error)

proc ecRecover*(er: var EcRecover; header: BlockHeader): EcAddrResult
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Variant of `ecRecover()` for call-by-value header
  var hdr = header
  er.ecRecover(hdr)

proc ecRecover*(er: var EcRecover; hash: Hash256): EcAddrResult
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Variant of `ecRecover()` for hash only. Will only succeed it the
  ## argument hash is uk the LRU queue.
  let rc = er.q.lruFetch(hash.data)
  if rc.isOK:
    return ok(rc.value)
  err((errItemNotFound,""))

# ------------------------------------------------------------------------------
# Public RLP mixin functions for caching version
# ------------------------------------------------------------------------------

proc append*(rw: var RlpWriter; data: EcRecover)
    {.raises: [Defect,KeyError].} =
  ## Generic support for `rlp.encode()`
  rw.append((data.size,data.q))

proc read*(rlp: var Rlp; Q: type EcRecover): Q
    {.raises: [Defect,KeyError].} =
  ## Generic support for `rlp.decode()` for loading the cache from a
  ## serialised data stream.
  (result.size, result.q) = rlp.read((type result.size, type result.q))

# ------------------------------------------------------------------------------
# Debugging
# ------------------------------------------------------------------------------

iterator keyItemPairs*(er: var EcRecover): (EcKey,EthAddress)
    {.gcsafe, raises: [Defect,CatchableError].} =
  var rc = er.q.first
  while rc.isOK:
    yield (rc.value.key, rc.value.data)
    rc = er.q.next(rc.value.key)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
