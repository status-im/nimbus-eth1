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
  ../utils_defs,
  ../lru_cache,
  ../../constants,
  eth/[common, keys, rlp],
  nimcrypto,
  stew/results,
  stint

const
  INMEMORY_SIGNATURES* = ##\
    ## Number of recent block signatures to keep in memory
    4096

type
  # simplify Hash256 for rlp serialisation
  EcKey32* = array[32, byte]

  EcRecover* = LruCache[BlockHeader,EcKey32,EthAddress,UtilsError]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc encodePreSealed(header: BlockHeader): seq[byte] {.inline.} =
  ## Cut sigature off `extraData` header field and consider new `baseFee`
  ## field for Eip1559.
  doAssert EXTRA_SEAL < header.extraData.len

  var rlpHeader = header
  rlpHeader.extraData.setLen(header.extraData.len - EXTRA_SEAL)
  rlp.encode(rlpHeader)


proc hashPreSealed(header: BlockHeader): Hash256 {.inline.} =
  ## Returns the hash of a block prior to it being sealed.
  keccak256.digest header.encodePreSealed


proc ecRecover*(extraData: openArray[byte];
                hash: Hash256): Result[EthAddress,UtilsError] {.inline.} =
  ## Extract account address from the last 65 bytes of the `extraData` argument
  ## (which is typically the bock header field with the same name.) The second
  ## argument `hash` is used to extract the intermediate public key. Typically,
  ## this would be the hash of the block header without the last 65 bytes of
  ## the `extraData` field reserved for the signature.
  if extraData.len < EXTRA_SEAL:
    return err((errMissingSignature,""))

  let sig = Signature.fromRaw(
    extraData.toOpenArray(extraData.len - EXTRA_SEAL, extraData.high))
  if sig.isErr:
    return err((errSkSigResult,$sig.error))

  # Recover the public key from signature and seal hash
  let pubKey = recover(sig.value, SKMessage(hash.data))
  if pubKey.isErr:
    return err((errSkPubKeyResult,$pubKey.error))

  # Convert public key to address.
  return ok(pubKey.value.toCanonicalAddress)

# ------------------------------------------------------------------------------
# Public function: straight ecRecover version
# ------------------------------------------------------------------------------

proc ecRecover*(header: BlockHeader): Result[EthAddress,UtilsError] =
  ## Extract account address from the `extraData` field (last 65 bytes) of the
  ## argument header.
  header.extraData.ecRecover(header.hashPreSealed)

# ------------------------------------------------------------------------------
# Public constructor for caching ecRecover version
# ------------------------------------------------------------------------------

proc initEcRecover*(cache: var EcRecover; cacheSize = INMEMORY_SIGNATURES) =

  var toKey: LruKey[BlockHeader,EcKey32] =
    proc(header:BlockHeader): EcKey32 =
      header.blockHash.data

  cache.initCache(toKey, ecRecover, cacheSize)

proc initEcRecover*: EcRecover {.gcsafe, raises: [Defect].} =
  result.initEcRecover

# ------------------------------------------------------------------------------
# Public function: caching ecRecover version
# ------------------------------------------------------------------------------

proc ecRecover*(addrCache: var EcRecover;
                header: BlockHeader): Result[EthAddress,UtilsError]
                  {.gcsafe, raises: [Defect,CatchableError].} =
  ## Extract account address from `extraData` field (last 65 bytes) of the
  ## argument header. The result is kept in a LRU cache to re-purposed for
  ## improved result delivery avoiding calculations.
  addrCache.getItem(header)

# ------------------------------------------------------------------------------
# Public PLP mixin functions for caching version
# ------------------------------------------------------------------------------

proc append*(rw: var RlpWriter; ecRec: EcRecover) {.
             inline, raises: [Defect,KeyError].} =
  ## Generic support for `rlp.encode(ecRec)`
  rw.append(ecRec.data)

proc read*(rlp: var Rlp; Q: type EcRecover): Q {.
           inline, raises: [Defect,KeyError].} =
  ## Generic support for `rlp.decode(bytes)` for loading the cache from a
  ## serialised data stream.
  result.initEcRecover
  result.data = rlp.read(type result.data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
