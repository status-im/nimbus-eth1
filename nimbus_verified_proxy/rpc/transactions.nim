# nimbus_verified_proxy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  stint,
  results,
  chronicles,
  eth/common/[base_rlp, transactions_rlp, receipts_rlp, hashes_rlp],
  ../../execution_chain/beacon/web3_eth_conv,
  eth/common/addresses,
  eth/common/eth_types_rlp,
  eth/trie/[hexary, ordered_trie, db, trie_defs],
  json_rpc/[rpcproxy, rpcserver, rpcclient],
  web3/[primitives, eth_api_types, eth_api],
  ../types,
  ../header_store

export results, stint, hashes_rlp, accounts_rlp, eth_api_types

template rpcClient(vp: VerifiedRpcProxy): RpcClient =
  vp.proxy.getClient()

template calcWithdrawalsRoot*(withdrawals: openArray[Withdrawal]): Root =
  orderedTrieRoot(withdrawals)

func vHashes(x: Opt[seq[Hash32]]): seq[VersionedHash] =
  if x.isNone:
    return
  else:
    x.get

func authList(x: Opt[seq[Authorization]]): seq[Authorization] =
  if x.isNone:
    return
  else:
    x.get

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
    versionedHashes: vHashes(tx.blobVersionedHashes),
    V: tx.v.uint64,
    R: tx.r,
    S: tx.s,
    authorizationList: authList(tx.authorizationList),
  )

proc toTransactions(
    txs: openArray[TxOrHash]
): seq[Transaction] {.raises: [ValueError].} =
  for x in txs:
    if x.kind == tohTx:
      result.add toTransaction(x.tx)
    else:
      raise newException(
        ValueError, "cannot construct a transaction trie using only txhashes"
      )

proc checkTxHash*(txObj: TransactionObject, txHash: Hash32): bool =
  let tx = toTransaction(txObj)
  if tx.rlpHash != txHash:
    return false

  return true

proc verifyTransactions*(
    txRoot: Hash32, transactions: seq[TxOrHash]
): Result[bool, string] =
  try:
    let txs = toTransactions(transactions)
    let rootHash = orderedTrieRoot(txs)
    if rootHash == txRoot:
      return ok(true)
  except ValueError as e:
    return err(e.msg)

  ok(false)
