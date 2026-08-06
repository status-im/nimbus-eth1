# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  ./[constants],
  ./core/pooled_txs_rlp,
  eth/common/[addresses, keys, transactions, transactions_rlp, transaction_utils],
  results

export addresses, keys, transactions, results

const senderCacheEnabled* {.booldefine.} = true

when senderCacheEnabled:
  import ./concurrency/lru

  const CACHE_CAPACITY = 1 shl 18

  var cache: ConcurrentLruCache[Hash32, Address]
  cache.init(CACHE_CAPACITY, threadSafe = true)

func recoverSender(msgHash: Hash32, sig: Signature): Opt[Address] =
  let pubkey = recover(sig, SkMessage(msgHash.data)).valueOr:
    return Opt.none(Address)
  Opt.some(pubkey.to(Address))

proc recoverSenderCached*(msgHash: Hash32, sig: Signature): Opt[Address] =
  when not senderCacheEnabled:
    recoverSender(msgHash, sig)
  else:
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
    sig = ?tx.signature()
    msgHash = tx.rlpHashForSigning(tx.isEip155())
  recoverSenderCached(msgHash, sig)

proc signTransaction*(
    tx: Transaction, privateKey: PrivateKey, eip155 = true
): Transaction =
  result = tx
  result.signature = result.sign(privateKey, eip155)

# deriveChainId derives the chain id from the given v parameter
func deriveChainId*(v: uint64, chainId: ChainId): ChainId =
  if v == 27 or v == 28:
    chainId
  else:
    ((v - 35) div 2).u256

func validateChainId*(tx: Transaction, chainId: ChainId): (bool, ChainId) =
  if tx.txType == TxLegacy:
    let derivedChainId = deriveChainId(tx.V, chainId)
    (chainId == derivedChainId, derivedChainId)
  else:
    (chainId == tx.chainId, tx.chainId)

func maxPriorityFeePerGasNorm*(tx: Transaction): GasInt =
  if tx.txType < TxEip1559: tx.gasPrice else: tx.maxPriorityFeePerGas

func maxFeePerGasNorm*(tx: Transaction): GasInt =
  if tx.txType < TxEip1559: tx.gasPrice else: tx.maxFeePerGas

func effectiveGasPrice*(tx: Transaction, baseFeePerGas: GasInt): GasInt =
  if tx.txType < TxEip1559:
    tx.gasPrice
  else:
    baseFeePerGas + min(tx.maxPriorityFeePerGas, tx.maxFeePerGas - baseFeePerGas)

func effectiveGasTip*(tx: Transaction, baseFeePerGas: Opt[UInt256]): GasInt =
  let baseFeePerGas = baseFeePerGas.get(0.u256).truncate(GasInt)

  min(tx.maxPriorityFeePerGasNorm(), tx.maxFeePerGasNorm() - baseFeePerGas)

proc decodeTx*(bytes: openArray[byte]): Transaction {.raises: [RlpError].} =
  var rlp = rlpFromBytes(bytes)
  result = rlp.read(Transaction)
  if rlp.hasData:
    raise newException(RlpError, "rlp: input contains more than one value")

proc decodePooledTx*(bytes: openArray[byte]): PooledTransaction {.raises: [RlpError].} =
  var rlp = rlpFromBytes(bytes)
  result = rlp.read(PooledTransaction)
  if rlp.hasData:
    raise newException(RlpError, "rlp: input contains more than one value")
