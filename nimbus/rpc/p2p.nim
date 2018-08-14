# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
import
  nimcrypto, json_rpc/rpcserver, eth_p2p, hexstrings, strutils, stint,
  ../config, ../vm_state, ../constants, eth_trie/[memdb, types],
  ../db/[db_chain, state_db], eth_common, rpc_types, byteutils

func headerFromTag(chain:BaseChainDB, blockTag: string): BlockHeader =
  let tag = blockTag.toLowerAscii
  case tag
  of "latest": result = chain.getCanonicalHead()
  of "earliest": result = chain.getCanonicalBlockHeaderByNumber(GENESIS_BLOCK_NUMBER)
  of "pending":
    #TODO: Implement get pending block
    raise newException(ValueError, "Pending tag not yet implemented")
  else:
    # Raises are trapped and wrapped in JSON when returned to the user.
    tag.validateHexQuantity
    let blockNum = stint.fromHex(UInt256, tag)
    result = chain.getCanonicalBlockHeaderByNumber(blockNum)

proc setupP2PRPC*(node: EthereumNode, rpcsrv: RpcServer) =
  template chain: untyped = BaseChainDB(node.chain) # TODO: Sensible casting
  
  proc accountDbFromTag(tag: string, readOnly = true): AccountStateDb =
    # Note: This is a read only account
    let
      header = chain.headerFromTag(tag)
      vmState = newBaseVMState(header, chain)
    result = vmState.chaindb.getStateDb(vmState.blockHeader.stateRoot, readOnly)

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
      sync.startingBlock = GENESIS_BLOCK_NUMBER.toHex.HexDataStr
      sync.currentBlock = chain.getCanonicalHead().blockNumber.toHex.HexDataStr
      sync.highestBlock = chain.getCanonicalHead().blockNumber.toHex.HexDataStr
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

  rpcsrv.rpc("eth_getBalance") do(data: EthAddressStr, quantityTag: string) -> int:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the current balance in wei.
    let
      account_db = accountDbFromTag(quantityTag)
      addrBytes = hexToPaddedByteArray[20](data.string)
      balance = account_db.get_balance(addrBytes)

    result = balance.toInt

  rpcsrv.rpc("eth_getStorageAt") do(data: EthAddressStr, quantity: int, quantityTag: string) -> HexDataStr:
    ## Returns the value from a storage position at a given address.
    ##
    ## data: address of the storage.
    ## quantity: integer of the position in the storage.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the value at this storage position.
    let
      account_db = accountDbFromTag(quantityTag)
      addrBytes = hexToPaddedByteArray[20](data.string)
      storage = account_db.getStorage(addrBytes, quantity.u256)
    if storage[1]:
      result = ("0x" & storage[0].toHex).HexDataStr


  rpcsrv.rpc("eth_getTransactionCount") do(data: EthAddressStr, quantityTag: string) -> int:
    ## Returns the number of transactions sent from an address.
    ##
    ## data: address.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the number of transactions send from this address.
    let
      header = chain.headerFromTag(quantityTag)
      body = chain.getBlockBody(header.stateRoot)
    result = body.transactions.len

  rpcsrv.rpc("eth_getBlockTransactionCountByHash") do(data: HexDataStr) -> int:
    ## Returns the number of transactions in a block from a block matching the given block hash.
    ##
    ## data: hash of a block
    ## Returns integer of the number of transactions in this block.
    var hashData: Hash256
    hashData.data = hexToPaddedByteArray[32](data.string)
    let body = chain.getBlockBody(hashData)
    result = body.transactions.len

  rpcsrv.rpc("eth_getBlockTransactionCountByNumber") do(quantityTag: string) -> int:
    ## Returns the number of transactions in a block matching the given block number.
    ##
    ## data: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## Returns integer of the number of transactions in this block.
    discard

  rpcsrv.rpc("eth_getUncleCountByBlockHash") do(data: HexDataStr):
    ## Returns the number of uncles in a block from a block matching the given block hash.
    ##
    ## data: hash of a block.
    ## Returns integer of the number of uncles in this block.
    discard

  rpcsrv.rpc("eth_getUncleCountByBlockNumber") do(quantityTag: string):
    ## Returns the number of uncles in a block from a block matching the given block number.
    ##
    ## quantityTag: integer of a block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of uncles in this block.
    discard

  rpcsrv.rpc("eth_getCode") do(data: EthAddressStr, quantityTag: string) -> HexDataStr:
    ## Returns code at a given address.
    ##
    ## data: address
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.
    discard

  rpcsrv.rpc("eth_sign") do(data: EthAddressStr, message: HexDataStr) -> HexDataStr:
    ## The sign method calculates an Ethereum specific signature with: sign(keccak256("\x19Ethereum Signed Message:\n" + len(message) + message))).
    ## By adding a prefix to the message makes the calculated signature recognisable as an Ethereum specific signature.
    ## This prevents misuse where a malicious DApp can sign arbitrary data (e.g. transaction) and use the signature to impersonate the victim.
    ## Note the address to sign with must be unlocked.
    ##
    ## data: address.
    ## message: message to sign.
    ## Returns signature.
    discard

  rpcsrv.rpc("eth_sendTransaction") do(obj: EthSend) -> HexDataStr:
    ## Creates new message call transaction or a contract creation, if the data field contains code.
    ##
    ## obj: the transaction object.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    discard

  rpcsrv.rpc("eth_sendRawTransaction") do(data: string, quantityTag: int) -> HexDataStr:
    ## Creates new message call transaction or a contract creation for signed transactions.
    ##
    ## data: the signed transaction data.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    discard

  rpcsrv.rpc("eth_call") do(call: EthCall, quantityTag: string) -> HexDataStr:
    ## Executes a new message call immediately without creating a transaction on the block chain.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the return value of executed contract.
    discard

  rpcsrv.rpc("eth_estimateGas") do(call: EthCall, quantityTag: string) -> HexDataStr: # TODO: Int or U/Int256?
    ## Generates and returns an estimate of how much gas is necessary to allow the transaction to complete.
    ## The transaction will not be added to the blockchain. Note that the estimate may be significantly more than
    ## the amount of gas actually used by the transaction, for a variety of reasons including EVM mechanics and node performance.
    ## 
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the amount of gas used.
    discard

  rpcsrv.rpc("eth_getBlockByHash") do(data: HexDataStr, fullTransactions: bool) -> BlockObject:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    discard

  rpcsrv.rpc("eth_getBlockByNumber") do(quantityTag: string, fullTransactions: bool) -> BlockObject:
    ## Returns information about a block by block number.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    discard

  rpcsrv.rpc("eth_getTransactionByHash") do(data: HexDataStr) -> TransactionObject:
    ## Returns the information about a transaction requested by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns requested transaction information.
    discard

  rpcsrv.rpc("eth_getTransactionByBlockHashAndIndex") do(data: HexDataStr, quantity: int) -> TransactionObject:
    ## Returns information about a transaction by block hash and transaction index position.
    ##
    ## data: hash of a block.
    ## quantity: integer of the transaction index position.
    ## Returns  requested transaction information.
    discard

  rpcsrv.rpc("eth_getTransactionByBlockNumberAndIndex") do(quantityTag: string, quantity: int) -> TransactionObject:
    ## Returns information about a transaction by block number and transaction index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the transaction index position.
    discard

  # Currently defined as a variant type so this might need rethinking
  # See: https://github.com/status-im/nim-json-rpc/issues/29
  #[
  rpcsrv.rpc("eth_getTransactionReceipt") do(data: HexDataStr) -> ReceiptObject:
    ## Returns the receipt of a transaction by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns transaction receipt.
    discard
  ]#

  rpcsrv.rpc("eth_getUncleByBlockHashAndIndex") do(data: HexDataStr, quantity: int64) -> BlockObject:
    ## Returns information about a uncle of a block by hash and uncle index position.  
    ##
    ## data: hash a block.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    discard

  rpcsrv.rpc("eth_getUncleByBlockNumberAndIndex") do(quantityTag: string, quantity: int64) -> BlockObject:
    # Returns information about a uncle of a block by number and uncle index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    discard

  # FilterOptions requires more layout planning.
  # See: https://github.com/status-im/nim-json-rpc/issues/29
  #[
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
  ]#
  
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

  #[
  rpcsrv.rpc("eth_getFilterChanges") do(filterId: int) -> seq[LogObject]:
    ## Polling method for a filter, which returns an list of logs which occurred since last poll.
    ##
    ## filterId: the filter id.
    result = @[]

  rpcsrv.rpc("eth_getFilterLogs") do(filterId: int) -> seq[LogObject]:
    ## filterId: the filter id.
    ## Returns a list of all logs matching filter with given id.
    result = @[]

  rpcsrv.rpc("eth_getLogs") do(filterOptions: FilterOptions) -> seq[LogObject]:
    ## filterOptions: settings for this filter.
    ## Returns a list of all logs matching a given filter object.
    result = @[]
  ]#

  rpcsrv.rpc("eth_getWork") do() -> seq[HexDataStr]:
    ## Returns the hash of the current block, the seedHash, and the boundary condition to be met ("target").
    ## Returned list has the following properties:
    ## DATA, 32 Bytes - current block header pow-hash.
    ## DATA, 32 Bytes - the seed hash used for the DAG.
    ## DATA, 32 Bytes - the boundary condition ("target"), 2^256 / difficulty.
    result = @[]

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


