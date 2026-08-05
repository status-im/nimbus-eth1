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
  eth/common/[transaction_utils, transactions_rlp],
  results

export results


const CACHE_CAPACITY = 1 shl 18

var cache: ConcurrentLruCache[Hash32, Address]

cache.init(CACHE_CAPACITY, threadSafe = true)

func recoverSender(msgHash: Hash32, sig: Signature): Opt[Address] =
  let pubkey = recover(sig, SkMessage(msgHash.data)).valueOr:
    return Opt.none(Address)
  Opt.some(pubkey.to(Address))

proc recoverSenderCached*(
    msgHash: Hash32, sig: Signature
): Opt[Address] =
  let
    key = withKeccak256:
      h.update(msgHash.data)
      h.update(sig.toRaw())
    keyHash = cache.toKeyHash(key)

  var res: Opt[Address]

  cache.withGetByHash(keyHash, key, cached):
    res = Opt.some(cached)
  do:
    res = recoverSender(msgHash, sig)
    if res.isSome():
      cache.putByHash(keyHash, key, res[])

  res

proc recoverSenderCached*(tx: Transaction): Opt[Address] =
  let
    msgHash = tx.rlpHashForSigning(tx.isEip155())
    sig = ?tx.signature()
  recoverSenderCached(msgHash, sig)

