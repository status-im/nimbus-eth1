import
  stint,
  results,
  eth/common/eth_types_rlp,
  eth/trie/[ordered_trie, trie_defs],
  json_rpc/[rpcproxy, rpcserver, rpcclient],
  web3/[eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv,
  ../types,
  ./blocks

template toLog(lg: LogObject): Log =
  Log(address: lg.address, topics: lg.topics, data: lg.data)

func toLogs(logs: openArray[LogObject]): seq[Log] =
  result = newSeqOfCap[Log](logs.len)
  for lg in logs:
    result.add(toLog(lg))

func toReceipt(rec: ReceiptObject): Receipt =
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

func toReceipts(recs: openArray[ReceiptObject]): seq[Receipt] =
  for r in recs:
    result.add(toReceipt(r))

proc getReceipts*(
    vp: VerifiedRpcProxy, blockTag: BlockTag
): Future[Result[seq[ReceiptObject], string]] {.async.} =
  let
    header = (await vp.getHeader(blockTag)).valueOr:
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

proc getReceipts*(
    vp: VerifiedRpcProxy, blockHash: Hash32
): Future[Result[seq[ReceiptObject], string]] {.async.} =
  let
    header = (await vp.getHeader(blockHash)).valueOr:
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

proc getLogs*(
    vp: VerifiedRpcProxy, filterOptions: FilterOptions
): Future[Result[seq[LogObject], string]] {.async.} =
  let logObjs =
    try:
      await vp.rpcClient.eth_getLogs(filterOptions)
    except CatchableError as e:
      return err(e.msg)

  var res = newSeq[LogObject]()

  # store block hashes contains the logs so that we can batch receipt requests
  for lg in logObjs:
    if lg.blockHash.isSome():
      let lgBlkHash = lg.blockHash.get()
      # TODO: a cache will solve downloading the same block receipts for multiple logs
      var rxs = (await vp.getReceipts(lgBlkHash)).valueOr:
          return err(error)

      if lg.transactionIndex.isNone():
        for rx in rxs:
          for rxLog in rx.logs:
            # only add verified logs
            if rxLog.address == lg.address and rxLog.data == lg.data and
                rxLog.topics == lg.topics:
              res.add(lg)
      else:
        let
          txIdx = lg.transactionIndex.get()
          rx = rxs[distinctBase(txIdx)]

        # only add verified logs
        for rxLog in rx.logs:
          if rxLog.address == lg.address and rxLog.data == lg.data and rxLog.topics == lg.topics:
            res.add(lg)

  if res.len == 0:
    return err("no logs could be verified")

  return ok(res)
