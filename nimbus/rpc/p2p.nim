# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  strutils, times, options, tables,
  json_rpc/rpcserver, hexstrings, stint, stew/byteutils,
  eth/[common, keys, rlp, p2p], nimcrypto,
  eth/p2p/rlpx_protocols/eth_protocol,
  ../transaction, ../config, ../vm_state, ../constants, ../vm_types,
  ../utils, ../db/[db_chain, state_db],
  rpc_types, rpc_utils, ../vm/[message, computation],
  ../vm/interpreter/vm_forks

#[
  Note:
    * Hexstring types (HexQuantitySt, HexDataStr, EthAddressStr, EthHashStr)
      are parsed to check format before the RPC blocks are executed and will
      raise an exception if invalid.
    * Many of the RPC calls do not validate hex string types when output, only
      type cast to avoid extra processing.
]#

proc setupEthRpc*(node: EthereumNode, chain: BaseChainDB , server: RpcServer) =

  proc getAccountDb(header: BlockHeader): ReadOnlyStateDB =
    ## Retrieves the account db from canonical head
    # we don't use accounst_cache here because it's only read operations
    let ac = newAccountStateDB(chain.db, header.stateRoot, chain.pruneTrie)
    result = ReadOnlyStateDB(ac)

  proc accountDbFromTag(tag: string, readOnly = true): ReadOnlyStateDB =
    result = getAccountDb(chain.headerFromTag(tag))

  server.rpc("eth_protocolVersion") do() -> string:
    result = $eth_protocol.protocolVersion

  server.rpc("eth_syncing") do() -> JsonNode:
    ## Returns SyncObject or false when not syncing.
    # TODO: make sure we are not syncing
    # when we reach the recent block
    let numPeers = node.peerPool.connectedNodes.len
    if numPeers > 0:
      var sync = SyncState(
        startingBlock: encodeQuantity chain.startingBlock,
        currentBlock : encodeQuantity chain.currentBlock,
        highestBlock : encodeQuantity chain.highestBlock
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
    result = encodeQuantity(calculateMedianGasPrice(chain).uint64)

  server.rpc("eth_accounts") do() -> seq[EthAddressStr]:
    ## Returns a list of addresses owned by client.
    let conf = getConfiguration()
    result = newSeqOfCap[EthAddressStr](conf.accounts.len)
    for k in keys(conf.accounts):
      result.add ethAddressStr(k)

  server.rpc("eth_blockNumber") do() -> HexQuantityStr:
    ## Returns integer of the current block number the client is on.
    result = encodeQuantity(chain.getCanonicalHead().blockNumber)

  server.rpc("eth_getBalance") do(data: EthAddressStr, quantityTag: string) -> HexQuantityStr:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the current balance in wei.
    let
      accDB   = accountDbFromTag(quantityTag)
      address = data.toAddress
      balance = accDB.getBalance(address)
    result = encodeQuantity(balance)

  server.rpc("eth_getStorageAt") do(data: EthAddressStr, quantity: HexQuantityStr, quantityTag: string) -> HexDataStr:
    ## Returns the value from a storage position at a given address.
    ##
    ## data: address of the storage.
    ## quantity: integer of the position in the storage.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the value at this storage position.
    let
      accDB   = accountDbFromTag(quantityTag)
      address = data.toAddress
      key     = fromHex(Uint256, quantity.string)
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
      accDB   = accountDbFromTag(quantityTag)
    result = encodeQuantity(accDB.getNonce(address))

  server.rpc("eth_getBlockTransactionCountByHash") do(data: EthHashStr) -> HexQuantityStr:
    ## Returns the number of transactions in a block from a block matching the given block hash.
    ##
    ## data: hash of a block
    ## Returns integer of the number of transactions in this block.
    let
      blockHash = data.toHash
      header    = chain.getBlockHeader(blockHash)
      txCount   = chain.getTransactionCount(header.txRoot)
    result = encodeQuantity(txCount.uint)

  server.rpc("eth_getBlockTransactionCountByNumber") do(quantityTag: string) -> HexQuantityStr:
    ## Returns the number of transactions in a block matching the given block number.
    ##
    ## data: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## Returns integer of the number of transactions in this block.
    let
      header  = chain.headerFromTag(quantityTag)
      txCount = chain.getTransactionCount(header.txRoot)
    result = encodeQuantity(txCount.uint)

  server.rpc("eth_getUncleCountByBlockHash") do(data: EthHashStr) -> HexQuantityStr:
    ## Returns the number of uncles in a block from a block matching the given block hash.
    ##
    ## data: hash of a block.
    ## Returns integer of the number of uncles in this block.
    let
      blockHash   = data.toHash
      header      = chain.getBlockHeader(blockHash)
      unclesCount = chain.getUnclesCount(header.ommersHash)
    result = encodeQuantity(unclesCount.uint)

  server.rpc("eth_getUncleCountByBlockNumber") do(quantityTag: string) -> HexQuantityStr:
    ## Returns the number of uncles in a block from a block matching the given block number.
    ##
    ## quantityTag: integer of a block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of uncles in this block.
    let
      header      = chain.headerFromTag(quantityTag)
      unclesCount = chain.getUnclesCount(header.ommersHash)
    result = encodeQuantity(unclesCount.uint)

  server.rpc("eth_getCode") do(data: EthAddressStr, quantityTag: string) -> HexDataStr:
    ## Returns code at a given address.
    ##
    ## data: address
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.
    let
      accDB   = accountDbFromTag(quantityTag)
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
      conf    = getConfiguration()
      acc     = conf.getAccount(address).tryGet()
      msg     = hexToSeqByte(message.string)

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")
    result = ("0x" & sign(acc.privateKey, cast[string](msg))).HexDataStr

  server.rpc("eth_signTransaction") do(data: TxSend) -> HexDataStr:
    ## Signs a transaction that can be submitted to the network at a later time using with
    ## eth_sendRawTransaction
    let
      address = data.source.toAddress
      conf    = getConfiguration()
      acc     = conf.getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")

    let
      accDB    = accountDbFromTag("latest")
      tx       = unsignedTx(data, chain, accDB.getNonce(address) + 1)
      signedTx = signTransaction(tx, chain, acc.privateKey)
      rlpTx    = rlp.encode(signedTx)

    result = hexDataStr(rlpTx)

  server.rpc("eth_sendTransaction") do(data: TxSend) -> EthHashStr:
    ## Creates new message call transaction or a contract creation, if the data field contains code.
    ##
    ## obj: the transaction object.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    # TODO: Relies on pending pool implementation
    let
      address = data.source.toAddress
      conf    = getConfiguration()
      acc     = conf.getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")

    let
      accDB    = accountDbFromTag("latest")
      tx       = unsignedTx(data, chain, accDB.getNonce(address) + 1)
      signedTx = signTransaction(tx, chain, acc.privateKey)
      rlpTx    = rlp.encode(signedTx)

    result = keccak_256.digest(rlpTx).ethHashStr

  server.rpc("eth_sendRawTransaction") do(data: HexDataStr) -> EthHashStr:
    ## Creates new message call transaction or a contract creation for signed transactions.
    ##
    ## data: the signed transaction data.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    # TODO: Relies on pending pool implementation
    let rlpBytes = hexToSeqByte(data.string)
    result = keccak_256.digest(rlpBytes).ethHashStr

  server.rpc("eth_call") do(call: EthCall, quantityTag: string) -> HexDataStr:
    ## Executes a new message call immediately without creating a transaction on the block chain.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the return value of executed contract.
    let
      header   = headerFromTag(chain, quantityTag)
      callData = callData(call, true, chain)
    result = doCall(callData, header, chain)

  server.rpc("eth_estimateGas") do(call: EthCall, quantityTag: string) -> HexQuantityStr:
    ## Generates and returns an estimate of how much gas is necessary to allow the transaction to complete.
    ## The transaction will not be added to the blockchain. Note that the estimate may be significantly more than
    ## the amount of gas actually used by the transaction, for a variety of reasons including EVM mechanics and node performance.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the amount of gas used.
    let
      header   = chain.headerFromTag(quantityTag)
      callData = callData(call, false, chain)
    result = estimateGas(callData, header, chain, call.gas.isSome)

  server.rpc("eth_getBlockByHash") do(data: EthHashStr, fullTransactions: bool) -> Option[BlockObject]:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    var
      header: BlockHeader
      hash = data.toHash

    if chain.getBlockHeader(hash, header):
      result = some(populateBlockObject(header, chain, fullTransactions))

  server.rpc("eth_getBlockByNumber") do(quantityTag: string, fullTransactions: bool) -> Option[BlockObject]:
    ## Returns information about a block by block number.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    try:
      let header = chain.headerFromTag(quantityTag)
      result = some(populateBlockObject(header, chain, fullTransactions))
    except:
      result = none(BlockObject)

  server.rpc("eth_getTransactionByHash") do(data: EthHashStr) -> Option[TransactionObject]:
    ## Returns the information about a transaction requested by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns requested transaction information.
    let txDetails = chain.getTransactionKey(data.toHash())
    if txDetails.index < 0:
      return none(TransactionObject)

    let header = chain.getBlockHeader(txDetails.blockNumber)
    var tx: Transaction
    if chain.getTransaction(header.txRoot, txDetails.index, tx):
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
    if not chain.getBlockHeader(data.toHash(), header):
      return none(TransactionObject)

    var tx: Transaction
    if chain.getTransaction(header.txRoot, index, tx):
      result = some(populateTransactionObject(tx, header, index))

  server.rpc("eth_getTransactionByBlockNumberAndIndex") do(quantityTag: string, quantity: HexQuantityStr) -> Option[TransactionObject]:
    ## Returns information about a transaction by block number and transaction index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the transaction index position.
    let
      header = chain.headerFromTag(quantityTag)
      index  = hexToInt(quantity.string, int)

    var tx: Transaction
    if chain.getTransaction(header.txRoot, index, tx):
      result = some(populateTransactionObject(tx, header, index))

  server.rpc("eth_getTransactionReceipt") do(data: EthHashStr) -> Option[ReceiptObject]:
    ## Returns the receipt of a transaction by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns transaction receipt.

    let txDetails = chain.getTransactionKey(data.toHash())
    if txDetails.index < 0:
      return none(ReceiptObject)

    let header = chain.getBlockHeader(txDetails.blockNumber)
    var tx: Transaction
    if not chain.getTransaction(header.txRoot, txDetails.index, tx):
      return none(ReceiptObject)

    var
      idx = 0
      prevGasUsed = GasInt(0)

    for receipt in chain.getReceipts(header):
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
    if not chain.getBlockHeader(data.toHash(), header):
      return none(BlockObject)

    let uncles = chain.getUncles(header.ommersHash)
    if index < 0 or index >= uncles.len:
      return none(BlockObject)

    var uncle = populateBlockObject(uncles[index], chain, false, true)
    uncle.totalDifficulty = encodeQuantity(chain.getScore(header.hash))
    result = some(uncle)

  server.rpc("eth_getUncleByBlockNumberAndIndex") do(quantityTag: string, quantity: HexQuantityStr) -> Option[BlockObject]:
    # Returns information about a uncle of a block by number and uncle index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    let
      index  = hexToInt(quantity.string, int)
      header = chain.headerFromTag(quantityTag)
      uncles = chain.getUncles(header.ommersHash)

    if index < 0 or index >= uncles.len:
      return none(BlockObject)

    var uncle = populateBlockObject(uncles[index], chain, false, true)
    uncle.totalDifficulty = encodeQuantity(chain.getScore(header.hash))
    result = some(uncle)

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

  server.rpc("eth_getLogs") do(filterOptions: FilterOptions) -> seq[FilterLog]:
    ## filterOptions: settings for this filter.
    ## Returns a list of all logs matching a given filter object.
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
