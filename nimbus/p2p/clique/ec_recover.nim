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
  ../../utils,
  ../../utils/lru_cache,
  ./clique_defs,
  eth/[common, keys, rlp],
  stint

type
  # simplify Hash256 for rlp serialisation
  EcKey32 = array[32, byte]

  EcRecover* = LruCache[BlockHeader,EcKey32,EthAddress,CliqueError]

{.push raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initEcRecover*(cache: var EcRecover) {.gcsafe, raises: [Defect].} =

  var toKey: LruKey[BlockHeader,EcKey32] =

    # Use the seal hash for cache lookup
    proc(header:BlockHeader): EcKey32 =
      ## If the signature's already cached, return that
      # clique/clique.go(148): hash := header.Hash()
      header.hash.data

  var toValue: LruValue[BlockHeader,EthAddress,CliqueError] =

    # Retrieve signature from the header's extra data fields
    proc(header: BlockHeader): Result[EthAddress,CliqueError] =

      # Extract signature from extra data field (last 65 bytes)
      let msg = header.extraData

      # clique/clique.go(153): if len(header.Extra) < extraSeal {
      if msg.len < EXTRA_SEAL:
        return err((errMissingSignature,""))
      let signature = Signature.fromRaw(
        msg.toOpenArray(msg.len - EXTRA_SEAL, msg.high))
      if signature.isErr:
        return err((errSkSigResult,$signature.error))

      # Recover the public key from signature and seal hash
      # clique/clique.go(159): pubkey, err := crypto.Ecrecover( [..]
      let pubKey = recover(signature.value, SKMessage(header.hash.data))
      if pubKey.isErr:
        return err((errSkPubKeyResult,$pubKey.error))

      # Convert public key to address.
      return ok(pubKey.value.toCanonicalAddress)

  cache.initLruCache(toKey, toValue, INMEMORY_SIGNATURES)

proc initEcRecover*: EcRecover {.gcsafe, raises: [Defect].} =
  result.initEcRecover


# clique/clique.go(145): func ecrecover(header [..]
proc getEcRecover*(addrCache: var EcRecover; header: BlockHeader): auto =
  ## extract Ethereum account address from a signed header block, the relevant
  ## signature used is appended to the re-purposed extra data field
  addrCache.getLruItem(header)


proc append*(rw: var RlpWriter; ecRec: EcRecover) {.inline.} =
  ## Generic support for `rlp.encode(ecRec)`
  rw.append(ecRec.data)

proc read*(rlp: var Rlp; Q: type EcRecover): Q {.inline.} =
  ## Generic support for `rlp.decode(bytes)` for loading the cache from a
  ## serialised data stream.
  result.initEcRecover
  result.data = rlp.read(type result.data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
