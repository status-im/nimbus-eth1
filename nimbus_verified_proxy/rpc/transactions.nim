# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push gcsafe, raises: [].}

import
  stint,
  results,
  eth/common/eth_types_rlp,
  eth/trie/[ordered_trie, trie_defs],
  web3/[eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv

proc toTransaction(tx: TransactionObject): Transaction =
  Transaction(
    txType: tx.`type`.get(0.Web3Quantity).TxType,
    chainId: tx.chainId.get(0.u256),
    nonce: tx.nonce.AccountNonce,
    gasPrice: tx.gasPrice.GasInt,
    maxPriorityFeePerGas: tx.maxPriorityFeePerGas.get(0.Web3Quantity).GasInt,
    maxFeePerGas: tx.maxFeePerGas.get(0.Web3Quantity).GasInt,
    gasLimit: tx.gas.GasInt,
    to: tx.to,
    value: tx.value,
    payload: tx.input,
    accessList: tx.accessList.get(@[]),
    maxFeePerBlobGas: tx.maxFeePerBlobGas.get(0.u256),
    versionedHashes: tx.blobVersionedHashes.get(@[]),
    V: tx.v.uint64,
    R: tx.r,
    S: tx.s,
    authorizationList: tx.authorizationList.get(@[]),
  )

proc toTransactions(txs: openArray[TxOrHash]): Result[seq[Transaction], string] =
  var convertedTxs = newSeqOfCap[Transaction](txs.len)
  for x in txs:
    if x.kind == tohTx:
      convertedTxs.add toTransaction(x.tx)
    else:
      return err("cannot construct a transaction trie using only txhashes")

  return ok(convertedTxs)

proc checkTxHash*(txObj: TransactionObject, txHash: Hash32): bool =
  toTransaction(txObj).rlpHash == txHash

proc verifyTransactions*(
    txRoot: Hash32, transactions: seq[TxOrHash]
): Result[void, string] =
  let
    txs = toTransactions(transactions).valueOr:
      return err(error)
    rootHash = orderedTrieRoot(txs)

  if rootHash == txRoot:
    return ok()

  err("calculated tx trie root doesn't match the provided tx trie root")
