# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  strutils, times, options,
  json_rpc/rpcserver, hexstrings, stint, byteutils, ranges/typedranges,
  eth/[common, keys, rlp, p2p], eth/trie/db, nimcrypto,
  ../transaction, ../config, ../vm_state, ../constants, ../vm_types,
  ../vm_state_transactions, ../utils,
  ../db/[db_chain, state_db, storage_types],
  rpc_types, rpc_utils, ../vm/[message, computation]

#[
  Note:
    * Hexstring types (HexQuantitySt, HexDataStr, EthAddressStr, EthHashStr)
      are parsed to check format before the RPC blocks are executed and will
      raise an exception if invalid.
    * Many of the RPC calls do not validate hex string types when output, only
      type cast to avoid extra processing.
]#

# Work around for https://github.com/nim-lang/Nim/issues/8645
proc `%`*(value: Time): JsonNode =
  result = %value.toSeconds

template balance(addressDb: ReadOnlyStateDb, address: EthAddress): GasInt =
  # TODO: Account balance u256 but GasInt is int64?
  addressDb.getBalance(address).truncate(int64)

proc binarySearchGas(vmState: var BaseVMState, transaction: Transaction, sender: EthAddress, gasPrice: GasInt, tolerance = 1): GasInt =
  proc dummyComputation(vmState: var BaseVMState, transaction: Transaction, sender: EthAddress): BaseComputation =
    let recipient = transaction.getRecipient()
    # Note that vmState may be altered
    setupComputation(
        vmState,
        transaction,
        sender, 
        recipient)

  proc dummyTransaction(gasLimit, gasPrice: GasInt, destination: EthAddress, value: UInt256): Transaction =
    Transaction(
      accountNonce: 0.AccountNonce,
      gasPrice: gasPrice,
      gasLimit: gasLimit,
      to: destination,
      value: value
    )
  var
    hiGas = vmState.gasLimit
    loGas = transaction.intrinsicGas
    gasPrice = transaction.gasPrice # TODO: Or zero?

  proc tryTransaction(vmState: var BaseVMState, gasLimit: GasInt): bool =
    var
      spoofTransaction = dummyTransaction(gasLimit, gasPrice, transaction.to, transaction.value)
      computation = vmState.dummyComputation(spoofTransaction, sender)
    computation.executeOpcodes
    if not computation.isError:
      return true

  if vmState.tryTransaction(loGas):
    return loGas
  if not vmState.tryTransaction(hiGas):
    return 0.GasInt # TODO: Reraise error from computation

  var
    minVal = vmState.gasLimit
    maxVal = transaction.intrinsicGas
  while loGas - hiGas > tolerance:
    let midPoint = (loGas + hiGas) div 2
    if vmState.tryTransaction(midPoint):
      minVal = midPoint
    else:
      maxVal = midPoint
  result = minVal

proc setupEthRpc*(node: EthereumNode, chain: BaseChainDB, rpcsrv: RpcServer) =

  func getAccountDb(header: BlockHeader): ReadOnlyStateDB =
    ## Retrieves the account db from canonical head
    # TODO: header.stateRoot to prevStateRoot
    let vmState = newBaseVMState(header.stateRoot, header, chain)
    result = vmState.readOnlyStateDB()

  proc accountDbFromTag(tag: string, readOnly = true): ReadOnlyStateDB =
    result = getAccountDb(chain.headerFromTag(tag))

  proc getBlockBody(hash: KeccakHash): BlockBody =
    if not chain.getBlockBody(hash, result):
      raise newException(ValueError, "Cannot find hash")

  rpcsrv.rpc("net_version") do() -> uint:
    let conf = getConfiguration()
    result = conf.net.networkId

  rpcsrv.rpc("eth_syncing") do() -> JsonNode:
    ## Returns SyncObject or false when not syncing.
    # TODO: Requires PeerPool to check sync state.
    # TODO: Use variant objects
    var
      res: JsonNode
      sync: SyncState
    if true:
      # TODO: Populate sync state, this is a placeholder
      sync.startingBlock = GENESIS_BLOCK_NUMBER
      sync.currentBlock = chain.getCanonicalHead().blockNumber
      sync.highestBlock = chain.getCanonicalHead().blockNumber
      result = %sync
    else:
      result = newJBool(false)

  rpcsrv.rpc("eth_coinbase") do() -> EthAddress:
    ## Returns the current coinbase address.
    result = chain.getCanonicalHead().coinbase

  rpcsrv.rpc("eth_mining") do() -> bool:
    ## Returns true if the client is mining, otherwise false.
    discard

  rpcsrv.rpc("eth_hashrate") do() -> int:
    ## Returns the number of hashes per second that the node is mining with.
    discard

  rpcsrv.rpc("eth_gasPrice") do() -> int64:
    ## Returns an integer of the current gas price in wei.
    discard

  rpcsrv.rpc("eth_accounts") do() -> seq[EthAddressStr]:
    ## Returns a list of addresses owned by client.
    result = @[]

  rpcsrv.rpc("eth_blockNumber") do() -> BlockNumber:
    ## Returns integer of the current block number the client is on.
    result = chain.getCanonicalHead().blockNumber

  rpcsrv.rpc("eth_getBalance") do(data: EthAddressStr, quantityTag: string) -> UInt256:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the current balance in wei.
    let
      accountDb = accountDbFromTag(quantityTag)
      addrBytes = data.toAddress
      balance = accountDb.getBalance(addrBytes)

    result = balance

  rpcsrv.rpc("eth_getStorageAt") do(data: EthAddressStr, quantity: int, quantityTag: string) -> UInt256:
    ## Returns the value from a storage position at a given address.
    ##
    ## data: address of the storage.
    ## quantity: integer of the position in the storage.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the value at this storage position.
    let
      accountDb = accountDbFromTag(quantityTag)
      addrBytes = data.toAddress
      storage = accountDb.getStorage(addrBytes, quantity.u256)
    if storage[1]:
      result = storage[0]

  rpcsrv.rpc("eth_getTransactionCount") do(data: EthAddressStr, quantityTag: string) -> AccountNonce:
    ## Returns the number of transactions sent from an address.
    ##
    ## data: address.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the number of transactions send from this address.
    let
      addrBytes = data.toAddress
      accountDb = accountDbFromTag(quantityTag)
    result = accountDb.getNonce(addrBytes)

  rpcsrv.rpc("eth_getBlockTransactionCountByHash") do(data: EthHashStr) -> int:
    ## Returns the number of transactions in a block from a block matching the given block hash.
    ##
    ## data: hash of a block
    ## Returns integer of the number of transactions in this block.
    var hashData = data.toHash
    result = getBlockBody(hashData).transactions.len

  rpcsrv.rpc("eth_getBlockTransactionCountByNumber") do(quantityTag: string) -> int:
    ## Returns the number of transactions in a block matching the given block number.
    ##
    ## data: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## Returns integer of the number of transactions in this block.
    let header = chain.headerFromTag(quantityTag)
    result = getBlockBody(header.hash).transactions.len

  rpcsrv.rpc("eth_getUncleCountByBlockHash") do(data: EthHashStr) -> int:
    ## Returns the number of uncles in a block from a block matching the given block hash.
    ##
    ## data: hash of a block.
    ## Returns integer of the number of uncles in this block.
    var hashData = data.toHash
    result = getBlockBody(hashData).uncles.len

  rpcsrv.rpc("eth_getUncleCountByBlockNumber") do(quantityTag: string) -> int:
    ## Returns the number of uncles in a block from a block matching the given block number.
    ##
    ## quantityTag: integer of a block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of uncles in this block.
    let header = chain.headerFromTag(quantityTag)
    result = getBlockBody(header.hash).uncles.len

  rpcsrv.rpc("eth_getCode") do(data: EthAddressStr, quantityTag: string) -> HexDataStr:
    ## Returns code at a given address.
    ##
    ## data: address
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.
    let
      accountDb = accountDbFromTag(quantityTag)
      addrBytes = toAddress(data)
      storage = accountDb.getCode(addrBytes)
    # Easier to return the string manually here rather than expect ByteRange to be marshalled
    result = byteutils.toHex(storage.toOpenArray).HexDataStr

  template sign(privateKey: PrivateKey, message: string): string =
    # TODO: Is message length encoded as bytes or characters?
    let msgData = "\x19Ethereum Signed Message:\n" & $message.len & message
    $signMessage(privateKey, msgData)

  rpcsrv.rpc("eth_sign") do(data: EthAddressStr, message: HexDataStr) -> HexDataStr:
    ## The sign method calculates an Ethereum specific signature with: sign(keccak256("\x19Ethereum Signed Message:\n" + len(message) + message))).
    ## By adding a prefix to the message makes the calculated signature recognisable as an Ethereum specific signature.
    ## This prevents misuse where a malicious DApp can sign arbitrary data (e.g. transaction) and use the signature to impersonate the victim.
    ## Note the address to sign with must be unlocked.
    ##
    ## data: address.
    ## message: message to sign.
    ## Returns signature.
    let accountDb = getAccountDb(chain.getCanonicalHead())
    var privateKey: PrivateKey  # TODO: Get from key store
    result = ("0x" & sign(privateKey, message.string)).HexDataStr

  proc setupTransaction(send: EthSend): Transaction =
    let
      source = send.source.toAddress
      destination = send.to.toAddress
      data = send.data.string.fromHex
      contractCreation = false  # TODO: Check if has code
      v = 0.byte # TODO
      r = 0.u256
      s = 0.u256
    result = initTransaction(send.nonce, send.gasPrice, send.gas, destination, send.value, data, v, r, s, contractCreation)

  rpcsrv.rpc("eth_sendTransaction") do(obj: EthSend) -> HexDataStr:
    ## Creates new message call transaction or a contract creation, if the data field contains code.
    ##
    ## obj: the transaction object.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    # TODO: Relies on pending pool implementation
    discard

  rpcsrv.rpc("eth_sendRawTransaction") do(data: string, quantityTag: int) -> HexDataStr:
    ## Creates new message call transaction or a contract creation for signed transactions.
    ##
    ## data: the signed transaction data.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    # TODO: Relies on pending pool implementation
    discard

  proc setupComputation(vmState: BaseVMState, blockNumber: BlockNumber,
      value: UInt256, data: seq[byte],
      sender, destination: EthAddress,
      gasLimit, gasPrice: GasInt): BaseComputation =
    let
      # Handle optional defaults.
      message = newMessage(
        gas = gasLimit,
        gasPrice = gasPrice,
        to = destination,
        sender = sender,
        value = value,
        data = data,
        code = vmState.readOnlyStateDB.getCode(destination).toSeq,
        options = newMessageOptions(origin = sender,
                                    createAddress = destination))

    result = newBaseComputation(vmState, blockNumber, message)

  rpcsrv.rpc("eth_call") do(call: EthCall, quantityTag: string) -> HexDataStr:
    ## Executes a new message call immediately without creating a transaction on the block chain.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the return value of executed contract.
    let header = headerFromTag(chain, quantityTag)
    var
      # TODO: header.stateRoot to prevStateRoot
      vmState = newBaseVMState(header.stateRoot, header, chain)
      gasLimit =
        if call.gas.isSome: call.gas.get
        else: 0.GasInt
      gasPrice =
        if call.gasPrice.isSome: call.gasPrice.get
        else: 0.GasInt

    # Set defaults for gas limit if required
    # Price remains zero by default
    if gaslimit == 0.GasInt:
      gasLimit = header.gasLimit

    var
      sender = if call.source.isSome: call.source.get.toAddress else: ZERO_ADDRESS
      # Note that destination is a required parameter for call.
      # In geth if it's zero they use the first wallet address,
      # if no wallets, remains as ZERO_ADDRESS
      # TODO: Wallets
      destination = if call.to.isSome: call.to.get.toAddress else: ZERO_ADDRESS
      data = if call.data.isSome: call.data.get.string.fromHex else: @[]
      value = if call.value.isSome: call.value.get else: 0.u256
      comp = setupComputation(vmState, header.blockNumber, value, data, sender, destination, gasLimit, gasPrice)

    discard comp.execComputation
    result = ("0x" & nimcrypto.toHex(comp.output)).HexDataStr

  rpcsrv.rpc("eth_estimateGas") do(call: EthCall, quantityTag: string) -> GasInt:
    ## Generates and returns an estimate of how much gas is necessary to allow the transaction to complete.
    ## The transaction will not be added to the blockchain. Note that the estimate may be significantly more than
    ## the amount of gas actually used by the transaction, for a variety of reasons including EVM mechanics and node performance.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the amount of gas used.
    var
      header = chain.headerFromTag(quantityTag)
      # TODO: header.stateRoot to prevStateRoot?
      vmState = newBaseVMState(header.stateRoot, header, chain)
    let
      gasLimit = if
        call.gas.isSome and call.gas.get > 0.GasInt: call.gas.get
        else: header.gasLimit
      gasPrice = if
        call.gasPrice.isSome and call.gasPrice.get > 0: call.gasPrice.get
        else: 0.GasInt
      sender = if
        call.source.isSome: call.source.get.toAddress
        else: ZERO_ADDRESS
      destination = if
        call.to.isSome: call.to.get.toAddress
        else: ZERO_ADDRESS
      curState = vmState.readOnlyStateDb()
      nonce = curState.getNonce(sender)
      value = if
        call.value.isSome: call.value.get
        else: 0.u256

      transaction = Transaction(
        accountNonce: nonce,
        gasPrice: gasPrice,
        gasLimit: gasLimit,
        to: destination,
        value: value,
        payload: @[]
      )
    result = vmState.binarySearchGas(transaction, sender, gasPrice)

  func populateBlockObject(header: BlockHeader, blockBody: BlockBody): BlockObject =
    result.number = some(header.blockNumber)
    result.hash = some(header.hash)
    result.parentHash = header.parentHash
    result.nonce = header.nonce.toUint

    # Calculate hash for all uncle headers
    var
      rawdata = newSeq[byte](blockBody.uncles.len * 32)
      startIdx = 0
    for i in 0 ..< blockBody.uncles.len:
      rawData[startIdx .. startIdx + 32] = blockBody.uncles[i].hash.data
      startIdx += 32
    result.sha3Uncles = keccakHash(rawData)

    result.logsBloom = some(header.bloom)
    result.transactionsRoot = header.txRoot
    result.stateRoot = header.stateRoot
    result.receiptsRoot = header.receiptRoot
    result.miner = ZERO_ADDRESS # TODO: Get miner address
    result.difficulty = header.difficulty
    result.totalDifficulty = header.difficulty  # TODO: Calculate
    result.extraData = header.extraData
    result.size = 0 # TODO: Calculate block size
    result.gasLimit = header.gasLimit
    result.gasUsed = header.gasUsed
    result.timestamp = header.timeStamp
    result.transactions = blockBody.transactions
    result.uncles = @[]
    for i in 0 ..< blockBody.uncles.len:
      result.uncles[i] = blockBody.uncles[i].hash

  rpcsrv.rpc("eth_getBlockByHash") do(data: EthHashStr, fullTransactions: bool) -> Option[BlockObject]:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    let
      h = data.toHash
      header = chain.getBlockHeader(h)
    result = some(populateBlockObject(header, getBlockBody(h)))

  rpcsrv.rpc("eth_getBlockByNumber") do(quantityTag: string, fullTransactions: bool) -> Option[BlockObject]:
    ## Returns information about a block by block number.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    let
      header = chain.headerFromTag(quantityTag)

    result = some(populateBlockObject(header, getBlockBody(header.hash)))

  proc populateTransactionObject(transaction: Transaction, txIndex: int64, blockHeader: BlockHeader, blockHash: Hash256): TransactionObject =
    let
      # TODO: header.stateRoot to prevStateRoot?
      vmState = newBaseVMState(blockHeader.stateRoot, blockHeader, chain)
      accountDb = vmState.readOnlyStateDB()
      address = transaction.getSender()
      txCount = accountDb.getNonce(address)
      txHash = transaction.rlpHash
      accountGas = accountDb.balance(address)

    result.hash = txHash
    result.nonce = txCount
    result.blockHash = some(blockHash)
    result.blockNumber = some(blockHeader.blockNumber)
    result.transactionIndex = some(txIndex)
    result.source = transaction.getSender()
    result.to = some(transaction.to)
    result.value = transaction.value
    result.gasPrice = transaction.gasPrice
    result.gas = accountGas
    result.input = transaction.payload

  rpcsrv.rpc("eth_getTransactionByHash") do(data: EthHashStr) -> TransactionObject:
    ## Returns the information about a transaction requested by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns requested transaction information.
    let
      h = data.toHash()
      txDetails = chain.getTransactionKey(h)
      header = chain.getBlockHeader(txDetails.blockNumber)
      blockHash = chain.getBlockHash(txDetails.blockNumber)
      transaction = getBlockBody(blockHash).transactions[txDetails.index]
    populateTransactionObject(transaction, txDetails.index, header, blockHash)
    # TODO: if the requested transaction not in blockchain
    # try to look for pending transaction in txpool

  rpcsrv.rpc("eth_getTransactionByBlockHashAndIndex") do(data: EthHashStr, quantity: int) -> TransactionObject:
    ## Returns information about a transaction by block hash and transaction index position.
    ##
    ## data: hash of a block.
    ## quantity: integer of the transaction index position.
    ## Returns  requested transaction information.
    let
      blockHash = data.toHash()
      header = chain.getBlockHeader(blockHash)
      transaction = getBlockBody(blockHash).transactions[quantity]
    populateTransactionObject(transaction, quantity, header, blockHash)

  rpcsrv.rpc("eth_getTransactionByBlockNumberAndIndex") do(quantityTag: string, quantity: int) -> TransactionObject:
    ## Returns information about a transaction by block number and transaction index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the transaction index position.
    let
      header = chain.headerFromTag(quantityTag)
      blockHash = header.hash
      transaction = getBlockBody(blockHash).transactions[quantity]
    populateTransactionObject(transaction, quantity, header, blockHash)

  proc populateReceipt(receipt: Receipt, gasUsed: GasInt, tx: Transaction, txIndex: int, blockHeader: BlockHeader): ReceiptObject =
    result.transactionHash = tx.rlpHash
    result.transactionIndex = txIndex
    result.blockHash = blockHeader.hash
    result.blockNumber = blockHeader.blockNumber
    result.sender = tx.getSender()
    result.to = some(tx.to)
    result.cumulativeGasUsed = receipt.cumulativeGasUsed
    result.gasUsed = gasUsed

    if tx.isContractCreation:
      var sender: EthAddress
      if tx.getSender(sender):
        let contractAddress = generateAddress(sender, tx.accountNonce)
        result.contractAddress = some(contractAddress)
      else:
        doAssert(false)
    else:
      result.contractAddress = none(EthAddress)

    result.logs = receipt.logs
    result.logsBloom = receipt.bloom
    # post-transaction stateroot (pre Byzantium).
    if receipt.hasStateRoot:
      result.root = some(receipt.stateRoot)
    else:
      # 1 = success, 0 = failure.
      result.status = some(receipt.status)

  rpcsrv.rpc("eth_getTransactionReceipt") do(data: EthHashStr) -> ReceiptObject:
    ## Returns the receipt of a transaction by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns transaction receipt.
    let
      h = data.toHash
      txDetails = chain.getTransactionKey(h)
      header = chain.getBlockHeader(txDetails.blockNumber)
      body = getBlockBody(header.hash)
    var
      idx = 0
      prevGasUsed = GasInt(0)

    for receipt in chain.getReceipts(header):
      let gasUsed = receipt.cumulativeGasUsed - prevGasUsed
      prevGasUsed = receipt.cumulativeGasUsed
      if idx == txDetails.index:
        return populateReceipt(receipt, gasUsed, body.transactions[txDetails.index], txDetails.index, header)
      idx.inc

  rpcsrv.rpc("eth_getUncleByBlockHashAndIndex") do(data: EthHashStr, quantity: int) -> Option[BlockObject]:
    ## Returns information about a uncle of a block by hash and uncle index position.
    ##
    ## data: hash of block.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    let
      blockHash = data.toHash()
      body = getBlockBody(blockHash)
    if quantity < 0 or quantity >= body.uncles.len:
      raise newException(ValueError, "Uncle index out of range")
    let uncle = body.uncles[quantity]
    result = some(populateBlockObject(uncle, body))

  rpcsrv.rpc("eth_getUncleByBlockNumberAndIndex") do(quantityTag: string, quantity: int) -> Option[BlockObject]:
    # Returns information about a uncle of a block by number and uncle index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    let
      header = chain.headerFromTag(quantityTag)
      body = getBlockBody(header.hash)
    if quantity < 0 or quantity >= body.uncles.len:
      raise newException(ValueError, "Uncle index out of range")
    let uncle = body.uncles[quantity]
    result = some(populateBlockObject(uncle, body))

  rpcsrv.rpc("eth_newFilter") do(filterOptions: FilterOptions) -> int:
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

  rpcsrv.rpc("eth_newBlockFilter") do() -> int:
    ## Creates a filter in the node, to notify when a new block arrives.
    ## To check if the state has changed, call eth_getFilterChanges.
    ##
    ## Returns integer filter id.
    discard

  rpcsrv.rpc("eth_newPendingTransactionFilter") do() -> int:
    ## Creates a filter in the node, to notify when a new block arrives.
    ## To check if the state has changed, call eth_getFilterChanges.
    ##
    ## Returns integer filter id.
    discard

  rpcsrv.rpc("eth_uninstallFilter") do(filterId: int) -> bool:
    ## Uninstalls a filter with given id. Should always be called when watch is no longer needed.
    ## Additonally Filters timeout when they aren't requested with eth_getFilterChanges for a period of time.
    ##
    ## filterId: The filter id.
    ## Returns true if the filter was successfully uninstalled, otherwise false.
    discard

  rpcsrv.rpc("eth_getFilterChanges") do(filterId: int) -> seq[FilterLog]:
    ## Polling method for a filter, which returns an list of logs which occurred since last poll.
    ##
    ## filterId: the filter id.
    result = @[]

  rpcsrv.rpc("eth_getFilterLogs") do(filterId: int) -> seq[FilterLog]:
    ## filterId: the filter id.
    ## Returns a list of all logs matching filter with given id.
    result = @[]

  rpcsrv.rpc("eth_getLogs") do(filterOptions: FilterOptions) -> seq[FilterLog]:
    ## filterOptions: settings for this filter.
    ## Returns a list of all logs matching a given filter object.
    result = @[]

  rpcsrv.rpc("eth_getWork") do() -> array[3, UInt256]:
    ## Returns the hash of the current block, the seedHash, and the boundary condition to be met ("target").
    ## Returned list has the following properties:
    ## DATA, 32 Bytes - current block header pow-hash.
    ## DATA, 32 Bytes - the seed hash used for the DAG.
    ## DATA, 32 Bytes - the boundary condition ("target"), 2^256 / difficulty.
    discard

  rpcsrv.rpc("eth_submitWork") do(nonce: int64, powHash: HexDataStr, mixDigest: HexDataStr) -> bool:
    ## Used for submitting a proof-of-work solution.
    ##
    ## nonce: the nonce found.
    ## headerPow: the header's pow-hash.
    ## mixDigest: the mix digest.
    ## Returns true if the provided solution is valid, otherwise false.
    discard

  rpcsrv.rpc("eth_submitHashrate") do(hashRate: HexDataStr, id: HexDataStr) -> bool:
    ## Used for submitting mining hashrate.
    ##
    ## hashRate: a hexadecimal string representation (32 bytes) of the hash rate.
    ## id: a random hexadecimal(32 bytes) ID identifying the client.
    ## Returns true if submitting went through succesfully and false otherwise.
    discard


