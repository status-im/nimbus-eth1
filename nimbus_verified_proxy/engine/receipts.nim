# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
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
): Future[seq[ReceiptObject]] {.async: (raises: [CancelledError, EngineError]).} =
  let rxs =
    try:
      await engine.backend.eth_getBlockReceipts(blockTag)
    except EthBackendError as e:
      e.msg = "Receipts fetch failed: " & e.msg
      raise e

  if rxs.isSome():
    if orderedTrieRoot(toReceipts(rxs.get())) != header.receiptsRoot:
      raise newException(
        VerificationError,
        "downloaded receipts do not evaluate to the receipts root of the block",
      )
  else:
    raise newException(UnavailableDataError, "error downloading the receipts")

  rxs.get()

proc getReceipts*(
    engine: RpcVerificationEngine, blockTag: types.BlockTag
): Future[seq[ReceiptObject]] {.async: (raises: [CancelledError, EngineError]).} =
  let
    header = await engine.getHeader(blockTag)
    # all other tags are automatically resolved while getting the header
    numberTag = types.BlockTag(
      kind: BlockIdentifierKind.bidNumber, number: Quantity(header.number)
    )

  await engine.getReceipts(header, numberTag)

proc getReceipts*(
    engine: RpcVerificationEngine, blockHash: Hash32
): Future[seq[ReceiptObject]] {.async: (raises: [CancelledError, EngineError]).} =
  let
    header = await engine.getHeader(blockHash)
    numberTag = types.BlockTag(
      kind: BlockIdentifierKind.bidNumber, number: Quantity(header.number)
    )

  await engine.getReceipts(header, numberTag)

proc resolveFilterTags*(
    engine: RpcVerificationEngine, filter: FilterOptions
): FilterOptions {.raises: [UnavailableDataError].} =
  if filter.blockHash.isSome():
    return filter

  let
    fromBlock = filter.fromBlock.get(types.BlockTag(kind: bidAlias, alias: "latest"))
    toBlock = filter.toBlock.get(types.BlockTag(kind: bidAlias, alias: "latest"))
    fromBlockNumberTag = engine.resolveBlockTag(fromBlock)
    toBlockNumberTag = engine.resolveBlockTag(toBlock)

  FilterOptions(
    fromBlock: Opt.some(fromBlockNumberTag),
    toBlock: Opt.some(toBlockNumberTag),
    address: filter.address,
    topics: filter.topics,
    blockHash: filter.blockHash,
  )

proc verifyLogs*(
    engine: RpcVerificationEngine, filter: FilterOptions, logObjs: seq[LogObject]
) {.async: (raises: [CancelledError, EngineError]).} =
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
        rxs = await engine.getReceipts(lg.blockHash.get())
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
        raise newException(VerificationError, "one of the returned logs is invalid")

proc getLogs*(
    engine: RpcVerificationEngine, filter: FilterOptions
): Future[seq[LogObject]] {.async: (raises: [CancelledError, EngineError]).} =
  let
    resolvedFilter = engine.resolveFilterTags(filter)
    logObjs =
      try:
        await engine.backend.eth_getLogs(resolvedFilter)
      except EthBackendError as e:
        e.msg = "Logs fetch failed: " & e.msg
        raise e

  await engine.verifyLogs(resolvedFilter, logObjs)

  logObjs
