# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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
  ./utils_defs,
  eth/[common, common/transaction, keys, rlp],
  stew/keyed_queue,
  results,
  stint

export
  utils_defs, results

{.push raises: [].}

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

proc encodePreSealed(header: BlockHeader): seq[byte] =
  ## Cut sigature off `extraData` header field.
  if header.extraData.len < EXTRA_SEAL:
    return rlp.encode(header)

  var rlpHeader = header
  rlpHeader.extraData.setLen(header.extraData.len - EXTRA_SEAL)
  rlp.encode(rlpHeader)

proc hashPreSealed(header: BlockHeader): Hash256 =
  ## Returns the hash of a block prior to it being sealed.
  keccakHash header.encodePreSealed


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
  let pubKey = recover(sig.value, SkMessage(msg.data))
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

proc ecRecover*(er: var EcRecover; header: var BlockHeader): EcAddrResult =
  ## Extract account address from `extraData` field (last 65 bytes) of the
  ## argument header. The result is kept in a LRU cache to re-purposed for
  ## improved result delivery avoiding calculations.
  let key = header.blockHash.data
  block:
    let rc = er.q.lruFetch(key)
    if rc.isOk:
      return ok(rc.value)
  block:
    let rc = header.extraData.recoverImpl(header.hashPreSealed)
    if rc.isOk:
      return ok(er.q.lruAppend(key, rc.value, er.size.int))
    err(rc.error)

proc ecRecover*(er: var EcRecover; header: BlockHeader): EcAddrResult =
  ## Variant of `ecRecover()` for call-by-value header
  var hdr = header
  er.ecRecover(hdr)

proc ecRecover*(er: var EcRecover; hash: Hash256): EcAddrResult =
  ## Variant of `ecRecover()` for hash only. Will only succeed it the
  ## argument hash is uk the LRU queue.
  let rc = er.q.lruFetch(hash.data)
  if rc.isOk:
    return ok(rc.value)
  err((errItemNotFound,""))

# ------------------------------------------------------------------------------
# Debugging
# ------------------------------------------------------------------------------

iterator keyItemPairs*(er: var EcRecover): (EcKey,EthAddress) =
  var rc = er.q.first
  while rc.isOk:
    yield (rc.value.key, rc.value.data)
    rc = er.q.next(rc.value.key)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
