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
  eth/trie/[ordered_trie, trie_defs],
  json_rpc/[rpcproxy, rpcserver, rpcclient],
  web3/[primitives, eth_api_types, eth_api],
  ../types,
  ./blocks

export results, stint, hashes_rlp, accounts_rlp, eth_api_types

template rpcClient(vp: VerifiedRpcProxy): RpcClient =
  vp.proxy.getClient()

template toLog(lg: LogObject): Log =
  Log(address: lg.address, topics: lg.topics, data: lg.data)

proc toLogs(logs: openArray[LogObject]): seq[Log] =
  result = map(
    logs,
    proc(x: LogObject): Log =
      toLog(x),
  )

proc toReceipt(rec: ReceiptObject): Receipt =
  let isHash = if rec.status.isSome: false else: true

  var status = false
  if rec.status.isSome:
    if rec.status.get() == 1.Quantity:
      status = true

  return Receipt(
    hash: rec.transactionHash,
    isHash: isHash,
    status: status,
    cumulativeGasUsed: rec.cumulativeGasUsed.GasInt,
    logs: toLogs(rec.logs),
    logsBloom: rec.logsBloom,
    receiptType: rec.`type`.get(0.Web3Quantity).ReceiptType,
  )

proc toReceipts(recs: openArray[ReceiptObject]): seq[Receipt] =
  for r in recs:
    result.add(toReceipt(r))

proc getReceiptsByBlockTag*(
    vp: VerifiedRpcProxy, blockTag: BlockTag
): Future[Result[seq[ReceiptObject], string]] {.async: (raises: []).} =
  let
    header = (await vp.getHeaderByTag(blockTag)).valueOr:
      return err(error)
    rxs =
      try:
        await vp.rpcClient.eth_getBlockReceipts(blockTag)
      except CatchableError as e:
        return err(e.msg)

  if rxs.isSome():
    if orderedTrieRoot(toReceipts(rxs.get())) != header.receiptsRoot:
      return
        err("downloaded receipts do not evaluate to the receipts root of the block")
  else:
    return err("error downloading the receipts")

  return ok(rxs.get())

proc getReceiptsByBlockHash*(
    vp: VerifiedRpcProxy, blockHash: Hash32
): Future[Result[seq[ReceiptObject], string]] {.async: (raises: []).} =
  let
    header = (await vp.getHeaderByHash(blockHash)).valueOr:
      return err(error)
    blockTag =
      BlockTag(RtBlockIdentifier(kind: bidNumber, number: Quantity(header.number)))
    rxs =
      try:
        await vp.rpcClient.eth_getBlockReceipts(blockTag)
      except CatchableError as e:
        return err(e.msg)

  if rxs.isSome():
    if orderedTrieRoot(toReceipts(rxs.get())) != header.receiptsRoot:
      return
        err("downloaded receipts do not evaluate to the receipts root of the block")
  else:
    return err("error downloading the receipts")

  return ok(rxs.get())
