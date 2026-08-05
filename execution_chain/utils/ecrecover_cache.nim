# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  ../concurrency/lru,
  eth/common/[
    addresses, hashes, keys, transactions, transaction_utils, eth_types_rlp
  ],
  results

export results

const cacheCapacity = 1 shl 16

var cache: ConcurrentLruCache[Hash32, Address]
cache.init(cacheCapacity, threadSafe = true)

template lookupOrRecover(key: Hash32, recovery: untyped): Opt[Address] =
  block:
    let keyHash = cache.toKeyHash(key)
    var res: Opt[Address]

    cache.withGetByHash(keyHash, key, cached):
      if cached != zeroAddress:
        res = Opt.some(cached)
    do:
      res = recovery
      cache.putByHash(keyHash, key, res.valueOr(zeroAddress))

    res

func recoverAddress(msgHash: array[32, byte], sig: Signature): Opt[Address] =
  let pubkey = recover(sig, SkMessage(msgHash)).valueOr:
    return Opt.none(Address)
  Opt.some(pubkey.toCanonicalAddress())

proc recoverSenderCached*(tx: Transaction, txHash: Hash32): Opt[Address] =
  lookupOrRecover(txHash, tx.recoverSender())

proc recoverSenderCached*(tx: Transaction): Opt[Address] =
  tx.recoverSenderCached(tx.computeRlpHash)

proc recoverAddressCached*(msgHash: array[32, byte], sig: Signature): Opt[Address] =
  var buf {.noinit.}: array[97, byte]
  buf[0 .. 31] = msgHash
  buf[32 .. 96] = sig.toRaw()

  lookupOrRecover(keccak256(buf), recoverAddress(msgHash, sig))
