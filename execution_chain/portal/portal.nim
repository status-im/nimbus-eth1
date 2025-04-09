# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  web3,
  chronos,
  chronicles,
  results,
  json_rpc/rpcclient,
  ../config,
  ../common,
  eth/common/[base, eth_types, keys]

logScope:
  topic = "portal"

type
  PortalRpc* = ref object
    url*: string
    provider: RpcClient

  HistoryExpiryRef* = ref object
    portalEnabled*: bool
    rpc: Opt[PortalRpc]
    limit*: base.BlockNumber # blockNumber limit till portal is activated, EIP specific

proc init*(T: type PortalRpc, url: string): T =
  let web3 = waitFor newWeb3(url)
  T(
    url: url,
    provider: web3.provider
  )

proc isPortalRpcEnabled*(conf: NimbusConf): bool =
  conf.portalUrl.len > 0

proc getPortalRpc(conf: NimbusConf): Opt[PortalRpc] =
  if isPortalRpcEnabled(conf):
    Opt.some(PortalRpc.init(conf.portalUrl))
  else:
    Opt.none(PortalRpc)

proc init*(T: type HistoryExpiryRef, conf: NimbusConf, com: CommonRef): T =
  # Portal is only available for mainnet
  notice "Initiating portal with the following config",
    portalUrl = conf.portalUrl,
    historyExpiry = conf.historyExpiry,
    networkId = com.networkId,
    portalLimit = conf.historyExpiryLimit
  
  if conf.historyExpiry:
    let 
      rpc = conf.getPortalRpc()
      portalEnabled =
        if com.networkId == MainNet and rpc.isSome:
          # Portal is only available for mainnet
          true
        else:
          warn "Portal is only available for mainnet, skipping fetching data from portal"
          false
      limit = 
        if conf.historyExpiryLimit.isSome:
          conf.historyExpiryLimit.get()
        else:
          com.posBlock().get()

    return T(
      portalEnabled: portalEnabled,
      rpc: rpc,
      limit: limit
    )
    
  else:
    # history expiry haven't been activated yet
    return nil

proc rpcProvider*(historyExpiry: HistoryExpiryRef): Result[RpcClient, string] =
  if historyExpiry.portalEnabled and historyExpiry.rpc.isSome:
    return ok(historyExpiry.rpc.get().provider)
  else:
    return err("Portal RPC is not enabled or not available")

proc toHeader(blkObj: BlockObject): Header =
  Header(
    parentHash: blkObj.parentHash,
    ommersHash: blkObj.sha3Uncles,
    coinbase: blkObj.miner,
    stateRoot: blkObj.stateRoot,
    transactionsRoot: blkObj.transactionsRoot,
    receiptsRoot: blkObj.receiptsRoot,
    logsBloom: blkObj.logsBloom,
    difficulty: blkObj.difficulty,
    number: uint64 blkObj.number,
    gasLimit: uint64 blkObj.gasLimit,
    gasUsed: uint64 blkObj.gasUsed,
    timestamp: EthTime blkObj.timestamp,
    extraData: seq[byte](blkObj.extraData),
    mixHash: Bytes32(blkObj.mixHash),
    nonce: blkObj.nonce.get(),
    baseFeePerGas: blkObj.baseFeePerGas,
    withdrawalsRoot: blkObj.withdrawalsRoot,
    blobGasUsed: if blkObj.blobGasUsed.isNone: Opt.none(uint64) else: Opt.some(uint64 blkObj.blobGasUsed.get()),
    excessBlobGas: if blkObj.excessBlobGas.isNone: Opt.none(uint64) else: Opt.some(uint64 blkObj.excessBlobGas.get()),
    parentBeaconBlockRoot: blkObj.parentBeaconBlockRoot,
    requestsHash: blkObj.requestsHash
  )

proc toTransactions(blkObj: BlockObject): seq[Transaction] =
  var txs: seq[Transaction] = @[]
  for txOrHash in blkObj.transactions:
    case txOrHash.kind
    of tohTx:
      # Convert the TransactionObject to a Transaction.
      let txType = TxType txOrHash.tx.`type`.get()
      let accessList =
        if txType >= TxEip2930:
          AccessList txOrHash.tx.accessList.get()
        else:
          @[]
      let (maxFeePerBlobGas, versionedHashes) =
        if txType >= TxEip4844:
          (txOrHash.tx.maxFeePerBlobGas.get(), txOrHash.tx.blobVersionedHashes.get())
        else:
          (0.u256, @[])
      let authorizationList =
        if txType >= TxEip7702:
          txOrHash.tx.authorizationList.get()
        else:
          @[]

      txs.add(
        Transaction(
          txType: txType,
          chainId: MainNet, # Portal RPC doesn't support other networks
          nonce: AccountNonce txOrHash.tx.nonce,
          gasPrice: GasInt txOrHash.tx.gasPrice,
          maxPriorityFeePerGas: GasInt txOrHash.tx.maxPriorityFeePerGas.get(),
          maxFeePerGas: GasInt txOrHash.tx.maxFeePerGas.get(),
          gasLimit: uint64 txOrHash.tx.gas,
          to: txOrHash.tx.to,
          value: txOrHash.tx.value,
          payload: txOrHash.tx.input,
          accessList: accessList,
          maxFeePerBlobGas: maxFeePerBlobGas,
          versionedHashes: versionedHashes,
          authorizationList: authorizationList,
          V: uint64 txOrHash.tx.v,
          R: txOrHash.tx.r,
          S: txOrHash.tx.s,
        )
      )
    of tohHash:
      continue
  return txs

proc toBlock(blkObj: BlockObject): Block =
  Block(
    header: toHeader(blkObj),
    transactions: toTransactions(blkObj),
    withdrawals: blkObj.withdrawals
  )

proc toBlockBody(blkObj: BlockObject): BlockBody =
  BlockBody(
    transactions: toTransactions(blkObj),
    uncles: @[],
    withdrawals: blkObj.withdrawals
  )

proc getBlockByNumber*(historyExpiry: HistoryExpiryRef, blockNumber: uint64, fullTxs: bool = true): Result[Block, string] =
  debug "Fetching block from portal"
  try:
    let 
      rpc = historyExpiry.rpcProvider.valueOr:
        return err("Portal RPC is not available")
      res = waitFor rpc.eth_getBlockByNumber(blockId(blockNumber), fullTxs)
    if res.isNil:
      return err("Block not found in portal")
    return ok(res.toBlock())
  except CatchableError as e:
    debug "Failed to fetch block from portal", err=e.msg
    return err(e.msg)

proc getBlockByHash*(historyExpiry: HistoryExpiryRef, blockHash: Hash32, fullTxs: bool = true): Result[Block, string] =
  debug "Fetching block from portal"
  try:
    let 
      rpc = historyExpiry.rpcProvider.valueOr:
        return err("Portal RPC is not available")
      res = waitFor rpc.eth_getBlockByHash(blockHash, fullTxs)
    if res.isNil:
      return err("Block not found in portal")
    return ok(res.toBlock())
  except CatchableError as e:
    debug "Failed to fetch block from portal", err=e.msg
    return err(e.msg)

proc getBlockBodyByHash*(historyExpiry: HistoryExpiryRef, blockHash: Hash32, fullTxs: bool = true): Result[BlockBody, string] =
  debug "Fetching block from portal"
  try:
    let 
      rpc = historyExpiry.rpcProvider.valueOr:
        return err("Portal RPC is not available")
      res = waitFor rpc.eth_getBlockByHash(blockHash, fullTxs)
    if res.isNil:
      return err("Block not found in portal")
    return ok(res.toBlockBody())
  except CatchableError as e:
    debug "Failed to fetch block from portal", err=e.msg
    return err(e.msg)

proc getHeaderByHash*(historyExpiry: HistoryExpiryRef, blockHash: Hash32): Result[Header, string] =
  debug "Fetching header from portal"
  try:
    let 
      rpc = historyExpiry.rpcProvider.valueOr:
        return err("Portal RPC is not available")
      res = waitFor rpc.eth_getBlockByHash(blockHash, false)
    if res.isNil:
      return err("Header not found in portal")
    return ok(res.toHeader())
  except CatchableError as e:
    debug "Failed to fetch header from portal", err=e.msg
    return err(e.msg)

proc getHeaderByNumber*(historyExpiry: HistoryExpiryRef, blockNumber: uint64): Result[Header, string] =
  debug "Fetching header from portal"
  try:
    let 
      rpc = historyExpiry.rpcProvider.valueOr:
        return err("Portal RPC is not available")
      res = waitFor rpc.eth_getBlockByNumber(blockId(blockNumber), false)
    if res.isNil:
      return err("Header not found in portal")
    return ok(res.toHeader())
  except CatchableError as e:
    debug "Failed to fetch header from portal", err=e.msg
    return err(e.msg)