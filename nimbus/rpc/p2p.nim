# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[times, tables, typetraits],
  json_rpc/rpcserver, stint, stew/byteutils,
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
  ../beacon/web3_eth_conv,
  ./filters

type
  BlockHeader = eth_types.BlockHeader
  Hash256 = eth_types.Hash256

proc getProof*(
    accDB: ReadOnlyStateDB,
    address: EthAddress,
    slots: seq[UInt256]): ProofResponse {.raises: [RlpError].} =
  let
    acc = accDB.getAccount(address)
    accExists = accDB.accountExists(address)
    accountProof = accDB.getAccountProof(address)
    slotProofs = accDB.getStorageProof(address, slots)

  var storage = newSeqOfCap[StorageProof](slots.len)

  for i, slotKey in slots:
    let (slotValue, _) = accDB.getStorage(address, u256(slotKey))
    storage.add(StorageProof(
        key: u256(slotKey),
        value: slotValue,
        proof: seq[RlpEncodedBytes](slotProofs[i])))

  if accExists:
    ProofResponse(
          address: w3Addr(address),
          accountProof: seq[RlpEncodedBytes](accountProof),
          balance: acc.balance,
          nonce: w3Qty(acc.nonce),
          codeHash: w3Hash(acc.codeHash),
          storageHash: w3Hash(acc.storageRoot),
          storageProof: storage)
  else:
    ProofResponse(
          address: w3Addr(address),
          accountProof: seq[RlpEncodedBytes](accountProof),
          storageProof: storage)

proc setupEthRpc*(
    node: EthereumNode, ctx: EthContext, com: CommonRef,
    txPool: TxPoolRef, server: RpcServer) =

  let chainDB = com.db
  proc getStateDB(header: BlockHeader): ReadOnlyStateDB =
    ## Retrieves the account db from canonical head
    # we don't use accounst_cache here because it's only read operations
    let ac = newAccountStateDB(chainDB, header.stateRoot, com.pruneTrie)
    result = ReadOnlyStateDB(ac)

  proc stateDBFromTag(quantityTag: BlockTag, readOnly = true): ReadOnlyStateDB
      {.gcsafe, raises: [CatchableError].} =
    result = getStateDB(chainDB.headerFromTag(quantityTag))

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

  server.rpc("eth_chainId") do() -> Web3Quantity:
    return w3Qty(distinctBase(com.chainId))

  server.rpc("eth_syncing") do() -> SyncingStatus:
    ## Returns SyncObject or false when not syncing.
    # TODO: make sure we are not syncing
    # when we reach the recent block
    let numPeers = node.peerPool.connectedNodes.len
    if numPeers > 0:
      var sync = SyncObject(
        startingBlock: w3Qty com.syncStart,
        currentBlock : w3Qty com.syncCurrent,
        highestBlock : w3Qty com.syncHighest
      )
      result = SyncingStatus(syncing: true, syncObject: sync)
    else:
      result = SyncingStatus(syncing: false)

  server.rpc("eth_coinbase") do() -> Web3Address:
    ## Returns the current coinbase address.
    # currently we don't have miner
    result = w3Address()

  server.rpc("eth_mining") do() -> bool:
    ## Returns true if the client is mining, otherwise false.
    # currently we don't have miner
    result = false

  server.rpc("eth_hashrate") do() -> Web3Quantity:
    ## Returns the number of hashes per second that the node is mining with.
    # currently we don't have miner
    result = w3Qty(0.uint)

  server.rpc("eth_gasPrice") do() -> Web3Quantity:
    ## Returns an integer of the current gas price in wei.
    result = w3Qty(calculateMedianGasPrice(chainDB).uint64)

  server.rpc("eth_accounts") do() -> seq[Web3Address]:
    ## Returns a list of addresses owned by client.
    result = newSeqOfCap[Web3Address](ctx.am.numAccounts)
    for k in ctx.am.addresses:
      result.add w3Addr(k)

  server.rpc("eth_blockNumber") do() -> Web3Quantity:
    ## Returns integer of the current block number the client is on.
    result = w3Qty(chainDB.getCanonicalHead().blockNumber)

  server.rpc("eth_getBalance") do(data: Web3Address, quantityTag: BlockTag) -> UInt256:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the current balance in wei.
    let
      accDB   = stateDBFromTag(quantityTag)
      address = data.ethAddr
    result = accDB.getBalance(address)

  server.rpc("eth_getStorageAt") do(data: Web3Address, slot: UInt256, quantityTag: BlockTag) -> FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    ##
    ## data: address of the storage.
    ## slot: integer of the position in the storage.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the value at this storage position.
    let
      accDB   = stateDBFromTag(quantityTag)
      address = data.ethAddr
    result = accDB.getStorage(address, slot)[0].w3FixedBytes

  server.rpc("eth_getTransactionCount") do(data: Web3Address, quantityTag: BlockTag) -> Web3Quantity:
    ## Returns the number of transactions sent from an address.
    ##
    ## data: address.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the number of transactions send from this address.
    let
      address = data.ethAddr
      accDB   = stateDBFromTag(quantityTag)
    result = w3Qty(accDB.getNonce(address))

  server.rpc("eth_getBlockTransactionCountByHash") do(data: Web3Hash) -> Web3Quantity:
    ## Returns the number of transactions in a block from a block matching the given block hash.
    ##
    ## data: hash of a block
    ## Returns integer of the number of transactions in this block.
    let
      blockHash = data.ethHash
      header    = chainDB.getBlockHeader(blockHash)
      txCount   = chainDB.getTransactionCount(header.txRoot)
    result = w3Qty(txCount)

  server.rpc("eth_getBlockTransactionCountByNumber") do(quantityTag: BlockTag) -> Web3Quantity:
    ## Returns the number of transactions in a block matching the given block number.
    ##
    ## data: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## Returns integer of the number of transactions in this block.
    let
      header  = chainDB.headerFromTag(quantityTag)
      txCount = chainDB.getTransactionCount(header.txRoot)
    result = w3Qty(txCount)

  server.rpc("eth_getUncleCountByBlockHash") do(data: Web3Hash) -> Web3Quantity:
    ## Returns the number of uncles in a block from a block matching the given block hash.
    ##
    ## data: hash of a block.
    ## Returns integer of the number of uncles in this block.
    let
      blockHash   = data.ethHash
      header      = chainDB.getBlockHeader(blockHash)
      unclesCount = chainDB.getUnclesCount(header.ommersHash)
    result = w3Qty(unclesCount)

  server.rpc("eth_getUncleCountByBlockNumber") do(quantityTag: BlockTag) -> Web3Quantity:
    ## Returns the number of uncles in a block from a block matching the given block number.
    ##
    ## quantityTag: integer of a block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of uncles in this block.
    let
      header      = chainDB.headerFromTag(quantityTag)
      unclesCount = chainDB.getUnclesCount(header.ommersHash)
    result = w3Qty(unclesCount.uint)

  server.rpc("eth_getCode") do(data: Web3Address, quantityTag: BlockTag) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## data: address
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.
    let
      accDB   = stateDBFromTag(quantityTag)
      address = data.ethAddr
    result = accDB.getCode(address)

  template sign(privateKey: PrivateKey, message: string): seq[byte] =
    # message length encoded as ASCII representation of decimal
    let msgData = "\x19Ethereum Signed Message:\n" & $message.len & message
    @(sign(privateKey, msgData.toBytes()).toRaw())

  server.rpc("eth_sign") do(data: Web3Address, message: seq[byte]) -> seq[byte]:
    ## The sign method calculates an Ethereum specific signature with: sign(keccak256("\x19Ethereum Signed Message:\n" + len(message) + message))).
    ## By adding a prefix to the message makes the calculated signature recognisable as an Ethereum specific signature.
    ## This prevents misuse where a malicious DApp can sign arbitrary data (e.g. transaction) and use the signature to impersonate the victim.
    ## Note the address to sign with must be unlocked.
    ##
    ## data: address.
    ## message: message to sign.
    ## Returns signature.
    let
      address = data.ethAddr
      acc     = ctx.am.getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")
    result = sign(acc.privateKey, cast[string](message))

  server.rpc("eth_signTransaction") do(data: EthSend) -> seq[byte]:
    ## Signs a transaction that can be submitted to the network at a later time using with
    ## eth_sendRawTransaction
    let
      address = data.`from`.ethAddr
      acc     = ctx.am.getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")

    let
      accDB    = stateDBFromTag(blockId("latest"))
      tx       = unsignedTx(data, chainDB, accDB.getNonce(address) + 1)
      eip155   = com.isEIP155(com.syncCurrent)
      signedTx = signTransaction(tx, acc.privateKey, com.chainId, eip155)
    result    = rlp.encode(signedTx)

  server.rpc("eth_sendTransaction") do(data: EthSend) -> Web3Hash:
    ## Creates new message call transaction or a contract creation, if the data field contains code.
    ##
    ## obj: the transaction object.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    let
      address = data.`from`.ethAddr
      acc     = ctx.am.getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")

    let
      accDB    = stateDBFromTag(blockId("latest"))
      tx       = unsignedTx(data, chainDB, accDB.getNonce(address) + 1)
      eip155   = com.isEIP155(com.syncCurrent)
      signedTx = signTransaction(tx, acc.privateKey, com.chainId, eip155)

    txPool.add(signedTx)
    result = rlpHash(signedTx).w3Hash

  server.rpc("eth_sendRawTransaction") do(txBytes: seq[byte]) -> Web3Hash:
    ## Creates new message call transaction or a contract creation for signed transactions.
    ##
    ## data: the signed transaction data.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    let
      signedTx = decodeTx(txBytes)
      txHash   = rlpHash(signedTx)

    txPool.add(signedTx)
    let res = txPool.inPoolAndReason(txHash)
    if res.isErr:
      raise newException(ValueError, res.error)
    result = txHash.w3Hash

  server.rpc("eth_call") do(call: EthCall, quantityTag: BlockTag) -> seq[byte]:
    ## Executes a new message call immediately without creating a transaction on the block chain.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the return value of executed contract.
    let
      header   = headerFromTag(chainDB, quantityTag)
      callData = callData(call)
      res      = rpcCallEvm(callData, header, com)
    result = res.output

  server.rpc("eth_estimateGas") do(call: EthCall) -> Web3Quantity:
    ## Generates and returns an estimate of how much gas is necessary to allow the transaction to complete.
    ## The transaction will not be added to the blockchain. Note that the estimate may be significantly more than
    ## the amount of gas actually used by the transaction, for a variety of reasons including EVM mechanics and node performance.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the amount of gas used.
    let
      # TODO: use latest spec EthCall
      header   = chainDB.headerFromTag(blockId("latest"))
      callData = callData(call)
      # TODO: DEFAULT_RPC_GAS_CAP should configurable
      gasUsed  = rpcEstimateGas(callData, header, com, DEFAULT_RPC_GAS_CAP)
    result = w3Qty(gasUsed)

  server.rpc("eth_getBlockByHash") do(data: Web3Hash, fullTransactions: bool) -> BlockObject:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    var
      header: BlockHeader
      hash = data.ethHash

    if chainDB.getBlockHeader(hash, header):
      result = populateBlockObject(header, chainDB, fullTransactions)
    else:
      result = nil

  server.rpc("eth_getBlockByNumber") do(quantityTag: BlockTag, fullTransactions: bool) -> BlockObject:
    ## Returns information about a block by block number.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    try:
      let header = chainDB.headerFromTag(quantityTag)
      result = populateBlockObject(header, chainDB, fullTransactions)
    except CatchableError:
      result = nil

  server.rpc("eth_getTransactionByHash") do(data: Web3Hash) -> TransactionObject:
    ## Returns the information about a transaction requested by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns requested transaction information.
    let txHash = data.ethHash()
    let res = txPool.getItem(txHash)
    if res.isOk:
      return populateTransactionObject(res.get().tx)

    let txDetails = chainDB.getTransactionKey(txHash)
    if txDetails.index < 0:
      return nil

    let header = chainDB.getBlockHeader(txDetails.blockNumber)
    var tx: Transaction
    if chainDB.getTransaction(header.txRoot, txDetails.index, tx):
      result = populateTransactionObject(tx, some(header), some(txDetails.index))

  server.rpc("eth_getTransactionByBlockHashAndIndex") do(data: Web3Hash, quantity: Web3Quantity) -> TransactionObject:
    ## Returns information about a transaction by block hash and transaction index position.
    ##
    ## data: hash of a block.
    ## quantity: integer of the transaction index position.
    ## Returns  requested transaction information.
    let index  = int(quantity)
    var header: BlockHeader
    if not chainDB.getBlockHeader(data.ethHash(), header):
      return nil

    var tx: Transaction
    if chainDB.getTransaction(header.txRoot, index, tx):
      result = populateTransactionObject(tx, some(header), some(index))
    else:
      result = nil

  server.rpc("eth_getTransactionByBlockNumberAndIndex") do(quantityTag: BlockTag, quantity: Web3Quantity) -> TransactionObject:
    ## Returns information about a transaction by block number and transaction index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the transaction index position.
    let
      header = chainDB.headerFromTag(quantityTag)
      index  = int(quantity)

    var tx: Transaction
    if chainDB.getTransaction(header.txRoot, index, tx):
      result = populateTransactionObject(tx, some(header), some(index))
    else:
      result = nil

  server.rpc("eth_getTransactionReceipt") do(data: Web3Hash) -> ReceiptObject:
    ## Returns the receipt of a transaction by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns transaction receipt.

    let txDetails = chainDB.getTransactionKey(data.ethHash())
    if txDetails.index < 0:
      return nil

    let header = chainDB.getBlockHeader(txDetails.blockNumber)
    var tx: Transaction
    if not chainDB.getTransaction(header.txRoot, txDetails.index, tx):
      return nil

    var
      idx = 0
      prevGasUsed = GasInt(0)

    for receipt in chainDB.getReceipts(header.receiptRoot):
      let gasUsed = receipt.cumulativeGasUsed - prevGasUsed
      prevGasUsed = receipt.cumulativeGasUsed
      if idx == txDetails.index:
        return populateReceipt(receipt, gasUsed, tx, txDetails.index, header)
      idx.inc

  server.rpc("eth_getUncleByBlockHashAndIndex") do(data: Web3Hash, quantity: Web3Quantity) -> BlockObject:
    ## Returns information about a uncle of a block by hash and uncle index position.
    ##
    ## data: hash of block.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    let index  = int(quantity)
    var header: BlockHeader
    if not chainDB.getBlockHeader(data.ethHash(), header):
      return nil

    let uncles = chainDB.getUncles(header.ommersHash)
    if index < 0 or index >= uncles.len:
      return nil

    result = populateBlockObject(uncles[index], chainDB, false, true)
    result.totalDifficulty = chainDB.getScore(header.hash)

  server.rpc("eth_getUncleByBlockNumberAndIndex") do(quantityTag: BlockTag, quantity: Web3Quantity) -> BlockObject:
    # Returns information about a uncle of a block by number and uncle index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    let
      index  = int(quantity)
      header = chainDB.headerFromTag(quantityTag)
      uncles = chainDB.getUncles(header.ommersHash)

    if index < 0 or index >= uncles.len:
      return nil

    result = populateBlockObject(uncles[index], chainDB, false, true)
    result.totalDifficulty = chainDB.getScore(header.hash)

  proc getLogsForBlock(
      chain: CoreDbRef,
      hash: Hash256,
      header: BlockHeader,
      opts: FilterOptions): seq[FilterLog]
        {.gcsafe, raises: [RlpError,ValueError].} =
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
      opts: FilterOptions): seq[FilterLog]
        {.gcsafe, raises: [RlpError,ValueError].} =
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
      let hash = ethHash filterOptions.blockHash.unsafeGet()
      let header = chainDB.getBlockHeader(hash)
      return getLogsForBlock(chainDB, hash, header, filterOptions)
    else:
      # TODO: do something smarter with tags. It would be the best if
      # tag would be an enum (Earliest, Latest, Pending, Number), and all operations
      # would operate on this enum instead of raw strings. This change would need
      # to be done on every endpoint to be consistent.
      let fromHeader = chainDB.headerFromTag(filterOptions.fromBlock)
      let toHeader = chainDB.headerFromTag(filterOptions.toBlock)

      # Note: if fromHeader.blockNumber > toHeader.blockNumber, no logs will be
      # returned. This is consistent with, what other ethereum clients return
      let logs = chainDB.getLogsForRange(
        fromHeader.blockNumber,
        toHeader.blockNumber,
        filterOptions
      )
      return logs



  server.rpc("eth_getProof") do(data: Web3Address, slots: seq[UInt256], quantityTag: BlockTag) -> ProofResponse:
    ## Returns information about an account and storage slots (if the account is a contract
    ## and the slots are requested) along with account and storage proofs which prove the
    ## existence of the values in the state.
    ## See spec here: https://eips.ethereum.org/EIPS/eip-1186
    ##
    ## data: address of the account.
    ## slots: integers of the positions in the storage to return with storage proofs.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the proof response containing the account, account proof and storage proof

    let
      accDB = stateDBFromTag(quantityTag)
      address = data.ethAddr

    getProof(accDB, address, slots)

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
