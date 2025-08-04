# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/sequtils,
  results,
  eth/common/eth_types_rlp,
  eth/trie/[ordered_trie, trie_defs],
  json_rpc/[rpcserver, rpcclient],
  web3/[eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv,
  ../../execution_chain/rpc/filters,
  ../types,
  ./blocks

template toLog(lg: LogObject): Log =
  Log(address: lg.address, topics: lg.topics, data: lg.data)

func toLogs(logs: openArray[LogObject]): seq[Log] =
  logs.mapIt(it.toLog)

func toReceipt(rec: ReceiptObject): Receipt =
  let isHash = not rec.status.isSome()

  let status = rec.status.isSome() and rec.status.get() == 1.Quantity

  return Receipt(
    hash: rec.transactionHash,
    isHash: isHash,
    status: status,
    cumulativeGasUsed: rec.cumulativeGasUsed.GasInt,
    logs: toLogs(rec.logs),
    logsBloom: rec.logsBloom,
    receiptType: rec.`type`.get(0.Web3Quantity).ReceiptType,
  )

func toReceipts(recs: openArray[ReceiptObject]): seq[Receipt] =
  recs.mapIt(it.toReceipt)

proc getReceipts(
    vp: VerifiedRpcProxy, header: Header, blockTag: types.BlockTag
): Future[Result[seq[ReceiptObject], string]] {.async.} =
  let rxs =
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

proc getReceipts*(
    vp: VerifiedRpcProxy, blockTag: types.BlockTag
): Future[Result[seq[ReceiptObject], string]] {.async.} =
  let
    header = (await vp.getHeader(blockTag)).valueOr:
      return err(error)
    # all other tags are automatically resolved while getting the header
    numberTag = types.BlockTag(
      kind: BlockIdentifierKind.bidNumber, number: Quantity(header.number)
    )

  await vp.getReceipts(header, numberTag)

proc getReceipts*(
    vp: VerifiedRpcProxy, blockHash: Hash32
): Future[Result[seq[ReceiptObject], string]] {.async.} =
  let
    header = (await vp.getHeader(blockHash)).valueOr:
      return err(error)
    numberTag = types.BlockTag(
      kind: BlockIdentifierKind.bidNumber, number: Quantity(header.number)
    )

  await vp.getReceipts(header, numberTag)

proc getLogs*(
    vp: VerifiedRpcProxy, filterOptions: FilterOptions
): Future[Result[seq[LogObject], string]] {.async.} =
  let logObjs =
    try:
      await vp.rpcClient.eth_getLogs(filterOptions)
    except CatchableError as e:
      return err(e.msg)

  # store block hashes contains the logs so that we can batch receipt requests
  var
    prevBlockHash: Hash32
    rxs: seq[ReceiptObject]

  for lg in logObjs:
    # none only for pending logs before block is built
    if lg.blockHash.isSome() and lg.transactionIndex.isSome() and lg.logIndex.isSome():
      # exploit sequentiality of logs 
      if prevBlockHash != lg.blockHash.get():
        # TODO: a cache will solve downloading the same block receipts for multiple logs
        rxs = (await vp.getReceipts(lg.blockHash.get())).valueOr:
          return err(error)
        prevBlockHash = lg.blockHash.get()

      let
        txIdx = distinctBase(lg.transactionIndex.get())
        logIdx =
          distinctBase(lg.logIndex.get()) -
          distinctBase(rxs[txIdx].logs[0].logIndex.get())
        rxLog = rxs[txIdx].logs[logIdx]

      if rxLog.address != lg.address or rxLog.data != lg.data or
          rxLog.topics != lg.topics or
          (not match(toLog(lg), filterOptions.address, filterOptions.topics)):
        return err("one of the returned logs is invalid")

  return ok(logObjs)
