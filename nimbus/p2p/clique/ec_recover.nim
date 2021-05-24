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
## Address Cache for Clique PoA Consensus Protocol
## ===============================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  ../../utils/lru_cache,
  ./clique_defs,
  eth/[common, keys, rlp],
  nimcrypto,
  stint

type
  # simplify Hash256 for rlp serialisation
  EcKey32 = array[32, byte]

  EcRecover* = LruCache[BlockHeader,EcKey32,EthAddress,CliqueError]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func sealHashData(header: BlockHeader): EcKey32 =
  ## hash of a block prior to it being sealed
  var curbed = header
  if EXTRA_SEAL <= curbed.extraData.len:
    curbed.extraData.setLen(curbed.extraData.len - EXTRA_SEAL)
  keccak256.digest(rlp.encode(curbed)).data

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initEcRecover*(cache: var EcRecover) =

  var toKey: LruKey[BlockHeader,EcKey32] =

    # Use the seal hash for cache lookup
    proc(header:BlockHeader): EcKey32 =
      header.sealHashData

  var toValue: LruValue[BlockHeader,EthAddress,CliqueError] =

    # Retrieve signature from the header's extra data fields
    proc(header: BlockHeader): Result[EthAddress,CliqueError] =

      # Extract signature from extra data field (last 65 bytes)
      let msg = header.extraData
      if msg.len < EXTRA_SEAL:
        return err((errMissingSignature,nilCStr))
      let sig = Signature.fromRaw(
        msg.toOpenArray(msg.len - EXTRA_SEAL, msg.high))
      if sig.isErr:
        return err((errSkSigResult,sig.error))

      # Recover the public key from signature and seal hash
      let pk = recover(sig.value, SKMessage(header.sealHashData))
      if pk.isErr:
        return err((errSkPubKeyResult,pk.error))

      # Convert public key to address.
      result = ok(pk.value.toCanonicalAddress)

  cache.initLruCache(toKey, toValue, INMEMORY_SIGNATURES)


proc getEcRecover*(addrCache: var EcRecover; header: BlockHeader): auto =
  ## extract Ethereum account address from a signed header block, the relevant
  ## signature used is appended to the re-purposed extra data field
  addrCache.getLruItem(header)

proc rlpEncodeEcRecover*(addrCache: var EcRecover): auto =
  addrCache.rlpEncodeLruCache

proc rlpLoadEcRecover*(data: openArray[byte]): EcRecover =
  result.initEcRecover
  result.rlpLoadLruCache(data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
