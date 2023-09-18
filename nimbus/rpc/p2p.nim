# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[times, tables, typetraits],
  json_rpc/rpcserver, hexstrings, stint, stew/byteutils,
  json_serialization, web3/conversions, json_serialization/std/options,
  eth/common/eth_types_json_serialization,
  eth/[keys, rlp, p2p],
  ".."/[transaction, vm_state, constants],
  ../db/state_db,
  rpc_types, rpc_utils,
  ../transaction/call_evm,
  ../core/tx_pool,
  ../common/[common, context],
  ../utils/utils,
  ./filters

#[
  Note:
    * Hexstring types (HexQuantitySt, HexDataStr, EthAddressStr, EthHashStr)
      are parsed to check format before the RPC blocks are executed and will
      raise an exception if invalid.
    * Many of the RPC calls do not validate hex string types when output, only
      type cast to avoid extra processing.
]#

# Annotation helpers
{.pragma:    noRaise, gcsafe, raises: [].}
{.pragma:   rlpRaise, gcsafe, raises: [RlpError].}
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

proc setupEthRpc*(
    node: EthereumNode, ctx: EthContext, com: CommonRef,
    txPool: TxPoolRef, server: RpcServer) =

  let chainDB = com.db
  proc getStateDB(header: BlockHeader): ReadOnlyStateDB {.catchRaise.} =
    ## Retrieves the account db from canonical head
    # we don't use accounst_cache here because it's only read operations
    let ac = newAccountStateDB(chainDB, header.stateRoot, com.pruneTrie)
    result = ReadOnlyStateDB(ac)

  proc stateDBFromTag(tag: string, readOnly = true): ReadOnlyStateDB
      {.catchRaise.} =
    result = getStateDB(chainDB.headerFromTag(tag))

  server.rpc("eth_protocolVersion") do() -> Option[string]:
    # Old Ethereum wiki documents this as returning a decimal string.
    # Infura documents this as returning 0x-prefixed hex string.
    # Geth 1.10.0 has removed this call "as it makes no sense".
    # - https://eth.wiki/json-rpc/API#eth_protocolversion
    # - https://infura.io/docs/ethereum/json-rpc/eth-protocolVersion
    # - https://blog.ethereum.org/2021/03/03/geth-v1-10-0/#compatibility
    for n in node.capabilities:
      if n.name == "eth":
        return some($n.version)
    return none(string)

  server.rpc("eth_chainId") do() -> HexQuantityStr:
    return encodeQuantity(distinctBase(com.chainId))

  server.rpc("eth_syncing") do() -> JsonNode:
    ## Returns SyncObject or false when not syncing.
    # TODO: make sure we are not syncing
    # when we reach the recent block
    let numPeers = node.peerPool.connectedNodes.len
    if numPeers > 0:
      var sync = SyncState(
        startingBlock: encodeQuantity com.syncStart,
        currentBlock : encodeQuantity com.syncCurrent,
        highestBlock : encodeQuantity com.syncHighest
      )
      result = %sync
    else:
      result = newJBool(false)

  server.rpc("eth_coinbase") do() -> EthAddress:
    ## Returns the current coinbase address.
    # currently we don't have miner
    result = default(EthAddress)

  server.rpc("eth_mining") do() -> bool:
    ## Returns true if the client is mining, otherwise false.
    # currently we don't have miner
    result = false

  server.rpc("eth_hashrate") do() -> HexQuantityStr:
    ## Returns the number of hashes per second that the node is mining with.
    # currently we don't have miner
    result = encodeQuantity(0.uint)

  server.rpc("eth_gasPrice") do() -> HexQuantityStr:
    ## Returns an integer of the current gas price in wei.
    result = encodeQuantity(calculateMedianGasPrice(chainDB).uint64)

  server.rpc("eth_accounts") do() -> seq[EthAddressStr]:
    ## Returns a list of addresses owned by client.
    result = newSeqOfCap[EthAddressStr](ctx.am.numAccounts)
    for k in ctx.am.addresses:
      result.add ethAddressStr(k)

  server.rpc("eth_blockNumber") do() -> HexQuantityStr:
    ## Returns integer of the current block number the client is on.
    result = encodeQuantity(chainDB.getCanonicalHead().blockNumber)

  server.rpc("eth_getBalance") do(data: EthAddressStr, quantityTag: string) -> HexQuantityStr:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the current balance in wei.
    let
      accDB   = stateDBFromTag(quantityTag)
      address = data.toAddress
      balance = accDB.getBalance(address)
    result = encodeQuantity(balance)

  server.rpc("eth_getStorageAt") do(data: EthAddressStr, slot: HexDataStr, quantityTag: string) -> HexDataStr:
    ## Returns the value from a storage position at a given address.
    ##
    ## data: address of the storage.
    ## slot: integer of the position in the storage.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the value at this storage position.
    let
      accDB   = stateDBFromTag(quantityTag)
      address = data.toAddress
      key     = fromHex(UInt256, slot.string)
      value   = accDB.getStorage(address, key)[0]
    result = hexDataStr(value)

  server.rpc("eth_getTransactionCount") do(data: EthAddressStr, quantityTag: string) -> HexQuantityStr:
    ## Returns the number of transactions sent from an address.
    ##
    ## data: address.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the number of transactions send from this address.
    let
      address = data.toAddress
      accDB   = stateDBFromTag(quantityTag)
    result = encodeQuantity(accDB.getNonce(address))

  server.rpc("eth_getBlockTransactionCountByHash") do(data: EthHashStr) -> HexQuantityStr:
    ## Returns the number of transactions in a block from a block matching the given block hash.
    ##
    ## data: hash of a block
    ## Returns integer of the number of transactions in this block.
    let
      blockHash = data.toHash
      header    = chainDB.getBlockHeader(blockHash)
      txCount   = chainDB.getTransactionCount(header.txRoot)
    result = encodeQuantity(txCount.uint)

  server.rpc("eth_getBlockTransactionCountByNumber") do(quantityTag: string) -> HexQuantityStr:
    ## Returns the number of transactions in a block matching the given block number.
    ##
    ## data: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## Returns integer of the number of transactions in this block.
    let
      header  = chainDB.headerFromTag(quantityTag)
      txCount = chainDB.getTransactionCount(header.txRoot)
    result = encodeQuantity(txCount.uint)

  server.rpc("eth_getUncleCountByBlockHash") do(data: EthHashStr) -> HexQuantityStr:
    ## Returns the number of uncles in a block from a block matching the given block hash.
    ##
    ## data: hash of a block.
    ## Returns integer of the number of uncles in this block.
    let
      blockHash   = data.toHash
      header      = chainDB.getBlockHeader(blockHash)
      unclesCount = chainDB.getUnclesCount(header.ommersHash)
    result = encodeQuantity(unclesCount.uint)

  server.rpc("eth_getUncleCountByBlockNumber") do(quantityTag: string) -> HexQuantityStr:
    ## Returns the number of uncles in a block from a block matching the given block number.
    ##
    ## quantityTag: integer of a block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of uncles in this block.
    let
      header      = chainDB.headerFromTag(quantityTag)
      unclesCount = chainDB.getUnclesCount(header.ommersHash)
    result = encodeQuantity(unclesCount.uint)

  server.rpc("eth_getCode") do(data: EthAddressStr, quantityTag: string) -> HexDataStr:
    ## Returns code at a given address.
    ##
    ## data: address
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.
    let
      accDB   = stateDBFromTag(quantityTag)
      address = data.toAddress
      storage = accDB.getCode(address)
    result = hexDataStr(storage)

  template sign(privateKey: PrivateKey, message: string): string =
    # message length encoded as ASCII representation of decimal
    let msgData = "\x19Ethereum Signed Message:\n" & $message.len & message
    $sign(privateKey, msgData.toBytes())

  server.rpc("eth_sign") do(data: EthAddressStr, message: HexDataStr) -> HexDataStr:
    ## The sign method calculates an Ethereum specific signature with: sign(keccak256("\x19Ethereum Signed Message:\n" + len(message) + message))).
    ## By adding a prefix to the message makes the calculated signature recognisable as an Ethereum specific signature.
    ## This prevents misuse where a malicious DApp can sign arbitrary data (e.g. transaction) and use the signature to impersonate the victim.
    ## Note the address to sign with must be unlocked.
    ##
    ## data: address.
    ## message: message to sign.
    ## Returns signature.
    let
      address = data.toAddress
      acc     = ctx.am.getAccount(address).tryGet()
      msg     = hexToSeqByte(message.string)

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")
    result = ("0x" & sign(acc.privateKey, cast[string](msg))).HexDataStr

  server.rpc("eth_signTransaction") do(data: TxSend) -> HexDataStr:
    ## Signs a transaction that can be submitted to the network at a later time using with
    ## eth_sendRawTransaction
    let
      address = data.source.toAddress
      acc     = ctx.am.getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")

    let
      accDB    = stateDBFromTag("latest")
      tx       = unsignedTx(data, chainDB, accDB.getNonce(address) + 1)
      eip155   = com.isEIP155(com.syncCurrent)
      signedTx = signTransaction(tx, acc.privateKey, com.chainId, eip155)
      rlpTx    = rlp.encode(signedTx)

    result = hexDataStr(rlpTx)

  server.rpc("eth_sendTransaction") do(data: TxSend) -> EthHashStr:
    ## Creates new message call transaction or a contract creation, if the data field contains code.
    ##
    ## obj: the transaction object.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    let
      address = data.source.toAddress
      acc     = ctx.am.getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")

    let
      accDB    = stateDBFromTag("latest")
      tx       = unsignedTx(data, chainDB, accDB.getNonce(address) + 1)
      eip155   = com.isEIP155(com.syncCurrent)
      signedTx = signTransaction(tx, acc.privateKey, com.chainId, eip155)

    txPool.add(signedTx)
    result = rlpHash(signedTx).ethHashStr

  server.rpc("eth_sendRawTransaction") do(data: HexDataStr) -> EthHashStr:
    ## Creates new message call transaction or a contract creation for signed transactions.
    ##
    ## data: the signed transaction data.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    let
      txBytes  = hexToSeqByte(data.string)
      signedTx = decodeTx(txBytes)
      txHash   = rlpHash(signedTx)

    txPool.add(signedTx)
    if not txPool.inPoolAndOk(txHash):
      raise newException(ValueError, "transaction rejected by txpool")
    result = txHash.ethHashStr

  server.rpc("eth_call") do(call: EthCall, quantityTag: string) -> HexDataStr:
    ## Executes a new message call immediately without creating a transaction on the block chain.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the return value of executed contract.
    let
      header   = headerFromTag(chainDB, quantityTag)
      callData = callData(call)
      res      = rpcCallEvm(callData, header, com)
    result = hexDataStr(res.output)

  server.rpc("eth_estimateGas") do(call: EthCall, quantityTag: string) -> HexQuantityStr:
    ## Generates and returns an estimate of how much gas is necessary to allow the transaction to complete.
    ## The transaction will not be added to the blockchain. Note that the estimate may be significantly more than
    ## the amount of gas actually used by the transaction, for a variety of reasons including EVM mechanics and node performance.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the amount of gas used.
    let
      header   = chainDB.headerFromTag(quantityTag)
      callData = callData(call)
      # TODO: DEFAULT_RPC_GAS_CAP should configurable
      gasUsed  = rpcEstimateGas(callData, header, com, DEFAULT_RPC_GAS_CAP)
    result = encodeQuantity(gasUsed.uint64)

  server.rpc("eth_getBlockByHash") do(data: EthHashStr, fullTransactions: bool) -> Option[BlockObject]:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    var
      header: BlockHeader
      hash = data.toHash

    if chainDB.getBlockHeader(hash, header):
      result = some populateBlockObject(header, chainDB, fullTransactions)
    else:
      result = none BlockObject

  server.rpc("eth_getBlockByNumber") do(quantityTag: string, fullTransactions: bool) -> Option[BlockObject]:
    ## Returns information about a block by block number.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    try:
      let header = chainDB.headerFromTag(quantityTag)
      result = some(populateBlockObject(header, chainDB, fullTransactions))
    except CatchableError:
      result = none(BlockObject)

  server.rpc("eth_getTransactionByHash") do(data: EthHashStr) -> Option[TransactionObject]:
    ## Returns the information about a transaction requested by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns requested transaction information.
    let txDetails = chainDB.getTransactionKey(data.toHash())
    if txDetails.index < 0:
      return none(TransactionObject)

    let header = chainDB.getBlockHeader(txDetails.blockNumber)
    var tx: Transaction
    if chainDB.getTransaction(header.txRoot, txDetails.index, tx):
      result = some(populateTransactionObject(tx, header, txDetails.index))

    # TODO: if the requested transaction not in blockchain
    # try to look for pending transaction in txpool

  server.rpc("eth_getTransactionByBlockHashAndIndex") do(data: EthHashStr, quantity: HexQuantityStr) -> Option[TransactionObject]:
    ## Returns information about a transaction by block hash and transaction index position.
    ##
    ## data: hash of a block.
    ## quantity: integer of the transaction index position.
    ## Returns  requested transaction information.
    let index  = hexToInt(quantity.string, int)
    var header: BlockHeader
    if not chainDB.getBlockHeader(data.toHash(), header):
      return none(TransactionObject)

    var tx: Transaction
    if chainDB.getTransaction(header.txRoot, index, tx):
      result = some(populateTransactionObject(tx, header, index))

  server.rpc("eth_getTransactionByBlockNumberAndIndex") do(quantityTag: string, quantity: HexQuantityStr) -> Option[TransactionObject]:
    ## Returns information about a transaction by block number and transaction index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the transaction index position.
    let
      header = chainDB.headerFromTag(quantityTag)
      index  = hexToInt(quantity.string, int)

    var tx: Transaction
    if chainDB.getTransaction(header.txRoot, index, tx):
      result = some(populateTransactionObject(tx, header, index))

  server.rpc("eth_getTransactionReceipt") do(data: EthHashStr) -> Option[ReceiptObject]:
    ## Returns the receipt of a transaction by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns transaction receipt.

    let txDetails = chainDB.getTransactionKey(data.toHash())
    if txDetails.index < 0:
      return none(ReceiptObject)

    let header = chainDB.getBlockHeader(txDetails.blockNumber)
    var tx: Transaction
    if not chainDB.getTransaction(header.txRoot, txDetails.index, tx):
      return none(ReceiptObject)

    var
      idx = 0
      prevGasUsed = GasInt(0)

    for receipt in chainDB.getReceipts(header.receiptRoot):
      let gasUsed = receipt.cumulativeGasUsed - prevGasUsed
      prevGasUsed = receipt.cumulativeGasUsed
      if idx == txDetails.index:
        return some(populateReceipt(receipt, gasUsed, tx, txDetails.index, header))
      idx.inc

  server.rpc("eth_getUncleByBlockHashAndIndex") do(data: EthHashStr, quantity: HexQuantityStr) -> Option[BlockObject]:
    ## Returns information about a uncle of a block by hash and uncle index position.
    ##
    ## data: hash of block.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    let index  = hexToInt(quantity.string, int)
    var header: BlockHeader
    if not chainDB.getBlockHeader(data.toHash(), header):
      return none(BlockObject)

    let uncles = chainDB.getUncles(header.ommersHash)
    if index < 0 or index >= uncles.len:
      return none(BlockObject)

    var uncle = populateBlockObject(uncles[index], chainDB, false, true)
    uncle.totalDifficulty = encodeQuantity(chainDB.getScore(header.hash))
    result = some(uncle)

  server.rpc("eth_getUncleByBlockNumberAndIndex") do(quantityTag: string, quantity: HexQuantityStr) -> Option[BlockObject]:
    # Returns information about a uncle of a block by number and uncle index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    let
      index  = hexToInt(quantity.string, int)
      header = chainDB.headerFromTag(quantityTag)
      uncles = chainDB.getUncles(header.ommersHash)

    if index < 0 or index >= uncles.len:
      return none(BlockObject)

    var uncle = populateBlockObject(uncles[index], chainDB, false, true)
    uncle.totalDifficulty = encodeQuantity(chainDB.getScore(header.hash))
    result = some(uncle)

  proc getLogsForBlock(
      chain: CoreDbRef,
      hash: Hash256,
      header: BlockHeader,
      opts: FilterOptions
        ): seq[FilterLog]
        {.catchRaise.} =
    if headerBloomFilter(header, opts.address, opts.topics):
      let blockBody = chain.getBlockBody(hash)
      let receipts = chain.getReceipts(header.receiptRoot)
      # Note: this will hit assertion error if number of block transactions
      # do not match block receipts.
      # Although this is fine as number of receipts should always match number
      # of transactions
      let logs = deriveLogs(header, blockBody.transactions, receipts)
      let filteredLogs = filterLogs(logs, opts.address, opts.topics)
      return filteredLogs
    else:
      return @[]

  proc getLogsForRange(
      chain: CoreDbRef,
      start: UInt256,
      finish: UInt256,
      opts: FilterOptions
        ): seq[FilterLog]
        {.catchRaise.} =
    var logs = newSeq[FilterLog]()
    var i = start
    while i <= finish:
      let res = chain.getBlockHeaderWithHash(i)
      if res.isSome():
        let (hash, header)= res.unsafeGet()
        let filtered = chain.getLogsForBlock(header, hash, opts)
        logs.add(filtered)
      else:
        #
        return logs
      i = i + 1
    return logs

  server.rpc("eth_getLogs") do(filterOptions: FilterOptions) -> seq[FilterLog]:
    ## filterOptions: settings for this filter.
    ## Returns a list of all logs matching a given filter object.
    ## TODO: Current implementation is pretty naive and not efficient
    ## as it requires to fetch all transactions and all receipts from database.
    ## Other clients (Geth):
    ## - Store logs related data in receipts.
    ## - Have separate indexes for Logs in given block
    ## Both of those changes require improvements to the way how we keep our data
    ## in Nimbus.
    if filterOptions.blockHash.isSome():
      let hash = filterOptions.blockHash.unsafeGet()
      let header = chainDB.getBlockHeader(hash)
      return getLogsForBlock(chainDB, hash, header, filterOptions)
    else:
      # TODO: do something smarter with tags. It would be the best if
      # tag would be an enum (Earliest, Latest, Pending, Number), and all operations
      # would operate on this enum instead of raw strings. This change would need
      # to be done on every endpoint to be consistent.
      let fromHeader = chainDB.headerFromTag(filterOptions.fromBlock)
      let toHeader = chainDB.headerFromTag(filterOptions.fromBlock)

      # Note: if fromHeader.blockNumber > toHeader.blockNumber, no logs will be
      # returned. This is consistent with, what other ethereum clients return
      let logs = chainDB.getLogsForRange(
        fromHeader.blockNumber,
        toHeader.blockNumber,
        filterOptions
      )
      return logs

#[
  server.rpc("eth_newFilter") do(filterOptions: FilterOptions) -> int:
    ## Creates a filter object, based on filter options, to notify when the state changes (logs).
    ## To check if the state has changed, call eth_getFilterChanges.
    ## Topics are order-dependent. A transaction with a log with topics [A, B] will be matched by the following topic filters:
    ## [] "anything"
    ## [A] "A in first position (and anything after)"
    ## [null, B] "anything in first position AND B in second position (and anything after)"
    ## [A, B] "A in first position AND B in second position (and anything after)"
    ## [[A, B], [A, B]] "(A OR B) in first position AND (A OR B) in second position (and anything after)"
    ##
    ## filterOptions: settings for this filter.
    ## Returns integer filter id.
    discard

  server.rpc("eth_newBlockFilter") do() -> int:
    ## Creates a filter in the node, to notify when a new block arrives.
    ## To check if the state has changed, call eth_getFilterChanges.
    ##
    ## Returns integer filter id.
    discard

  server.rpc("eth_newPendingTransactionFilter") do() -> int:
    ## Creates a filter in the node, to notify when a new block arrives.
    ## To check if the state has changed, call eth_getFilterChanges.
    ##
    ## Returns integer filter id.
    discard

  server.rpc("eth_uninstallFilter") do(filterId: int) -> bool:
    ## Uninstalls a filter with given id. Should always be called when watch is no longer needed.
    ## Additonally Filters timeout when they aren't requested with eth_getFilterChanges for a period of time.
    ##
    ## filterId: The filter id.
    ## Returns true if the filter was successfully uninstalled, otherwise false.
    discard

  server.rpc("eth_getFilterChanges") do(filterId: int) -> seq[FilterLog]:
    ## Polling method for a filter, which returns an list of logs which occurred since last poll.
    ##
    ## filterId: the filter id.
    result = @[]

  server.rpc("eth_getFilterLogs") do(filterId: int) -> seq[FilterLog]:
    ## filterId: the filter id.
    ## Returns a list of all logs matching filter with given id.
    result = @[]

  server.rpc("eth_getWork") do() -> array[3, UInt256]:
    ## Returns the hash of the current block, the seedHash, and the boundary condition to be met ("target").
    ## Returned list has the following properties:
    ## DATA, 32 Bytes - current block header pow-hash.
    ## DATA, 32 Bytes - the seed hash used for the DAG.
    ## DATA, 32 Bytes - the boundary condition ("target"), 2^256 / difficulty.
    discard

  server.rpc("eth_submitWork") do(nonce: int64, powHash: HexDataStr, mixDigest: HexDataStr) -> bool:
    ## Used for submitting a proof-of-work solution.
    ##
    ## nonce: the nonce found.
    ## headerPow: the header's pow-hash.
    ## mixDigest: the mix digest.
    ## Returns true if the provided solution is valid, otherwise false.
    discard

  server.rpc("eth_submitHashrate") do(hashRate: HexDataStr, id: HexDataStr) -> bool:
    ## Used for submitting mining hashrate.
    ##
    ## hashRate: a hexadecimal string representation (32 bytes) of the hash rate.
    ## id: a random hexadecimal(32 bytes) ID identifying the client.
    ## Returns true if submitting went through succesfully and false otherwise.
    discard]#
