# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/sequtils,
  results,
  eth/common/eth_types_rlp,
  eth/trie/[ordered_trie, trie_defs],
  json_rpc/[rpcserver, rpcclient],
  web3/[eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv,
  ../../execution_chain/rpc/filters,
  ./types,
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
    engine: RpcVerificationEngine, header: Header, blockTag: types.BlockTag
): Future[EngineResult[seq[ReceiptObject]]] {.async: (raises: [CancelledError]).} =
  let
    backend = ?(engine.backendFor(GetBlockReceipts))
    rxs = ?(await backend.eth_getBlockReceipts(blockTag))

  if rxs.isSome():
    if orderedTrieRoot(toReceipts(rxs.get())) != header.receiptsRoot:
      return err(
        (
          VerificationError,
          "downloaded receipts do not evaluate to the receipts root of the block",
        )
      )
  else:
    return err((VerificationError, "error downloading the receipts"))

  return ok(rxs.get())

proc getReceipts*(
    engine: RpcVerificationEngine, blockTag: types.BlockTag
): Future[EngineResult[seq[ReceiptObject]]] {.async: (raises: [CancelledError]).} =
  let
    header = ?(await engine.getHeader(blockTag))
    # all other tags are automatically resolved while getting the header
    numberTag = types.BlockTag(
      kind: BlockIdentifierKind.bidNumber, number: Quantity(header.number)
    )

  await engine.getReceipts(header, numberTag)

proc getReceipts*(
    engine: RpcVerificationEngine, blockHash: Hash32
): Future[EngineResult[seq[ReceiptObject]]] {.async: (raises: [CancelledError]).} =
  let
    header = ?(await engine.getHeader(blockHash))
    numberTag = types.BlockTag(
      kind: BlockIdentifierKind.bidNumber, number: Quantity(header.number)
    )

  await engine.getReceipts(header, numberTag)

proc resolveFilterTags*(
    engine: RpcVerificationEngine, filter: FilterOptions
): EngineResult[FilterOptions] =
  if filter.blockHash.isSome():
    return ok(filter)
  let
    fromBlock = filter.fromBlock.get(types.BlockTag(kind: bidAlias, alias: "latest"))
    toBlock = filter.toBlock.get(types.BlockTag(kind: bidAlias, alias: "latest"))
    fromBlockNumberTag = ?engine.resolveBlockTag(fromBlock)
    toBlockNumberTag = ?engine.resolveBlockTag(toBlock)

  return ok(
    FilterOptions(
      fromBlock: Opt.some(fromBlockNumberTag),
      toBlock: Opt.some(toBlockNumberTag),
      address: filter.address,
      topics: filter.topics,
      blockHash: filter.blockHash,
    )
  )

proc verifyLogs*(
    engine: RpcVerificationEngine, filter: FilterOptions, logObjs: seq[LogObject]
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
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
        rxs = ?(await engine.getReceipts(lg.blockHash.get()))
        prevBlockHash = lg.blockHash.get()
      let
        txIdx = distinctBase(lg.transactionIndex.get())
        logIdx =
          distinctBase(lg.logIndex.get()) -
          distinctBase(rxs[txIdx].logs[0].logIndex.get())
        rxLog = rxs[txIdx].logs[logIdx]

      if rxLog.address != lg.address or rxLog.data != lg.data or
          rxLog.topics != lg.topics or
          lg.blockNumber.get() < filter.fromBlock.get().number or
          lg.blockNumber.get() > filter.toBlock.get().number or
          (not match(toLog(lg), filter.address, filter.topics)):
        return err((VerificationError, "one of the returned logs is invalid"))

  ok()

proc getLogs*(
    engine: RpcVerificationEngine, filter: FilterOptions
): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
  let
    resolvedFilter = ?engine.resolveFilterTags(filter)
    backend = ?(engine.backendFor(GetLogs))
    logObjs = ?(await backend.eth_getLogs(resolvedFilter))

  ?(await engine.verifyLogs(resolvedFilter, logObjs))

  return ok(logObjs)
