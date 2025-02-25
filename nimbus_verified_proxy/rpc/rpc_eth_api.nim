# nimbus_verified_proxy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/strutils,
  results,
  chronicles,
  json_rpc/[rpcserver, rpcclient, rpcproxy],
  eth/common/accounts,
  web3/[primitives, eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv,
  ../../execution_chain/common/common,
  ../../execution_chain/db/ledger,
  ../../execution_chain/transaction/call_evm,
  ../../execution_chain/[evm/types, evm/state],
  ../validate_proof,
  ../block_cache

logScope:
  topics = "verified_proxy"

type
  VerifiedRpcProxy* = ref object
    proxy: RpcProxy
    blockCache: BlockCache
    chainId: UInt256

  QuantityTagKind = enum
    LatestBlock
    BlockNumber

  BlockTag = eth_api_types.RtBlockIdentifier

  QuantityTag = object
    case kind: QuantityTagKind
    of LatestBlock:
      discard
    of BlockNumber:
      blockNumber: Quantity

func parseQuantityTag(blockTag: BlockTag): Result[QuantityTag, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii
    case tag
    of "latest":
      return ok(QuantityTag(kind: LatestBlock))
    else:
      return err("Unsupported blockTag: " & tag)
  else:
    let quantity = blockTag.number
    return ok(QuantityTag(kind: BlockNumber, blockNumber: quantity))

template checkPreconditions(proxy: VerifiedRpcProxy) =
  if proxy.blockCache.isEmpty():
    raise newException(ValueError, "Syncing")

template rpcClient(lcProxy: VerifiedRpcProxy): RpcClient =
  lcProxy.proxy.getClient()

proc getBlockByTag(
    proxy: VerifiedRpcProxy, quantityTag: BlockTag
): results.Opt[BlockObject] {.raises: [ValueError].} =
  checkPreconditions(proxy)

  let tag = parseQuantityTag(quantityTag).valueOr:
    raise newException(ValueError, error)

  case tag.kind
  of LatestBlock:
    # this will always return some block, as we always checkPreconditions
    proxy.blockCache.latest
  of BlockNumber:
    proxy.blockCache.getByNumber(tag.blockNumber)

proc getBlockByHash(
    proxy: VerifiedRpcProxy, blockHash: Hash32
): results.Opt[BlockObject] {.raises: [ValueError].} =
  checkPreconditions(proxy)
  proxy.blockCache.getPayloadByHash(blockHash)

proc getBlockByTagOrThrow(
    proxy: VerifiedRpcProxy, quantityTag: BlockTag
): BlockObject {.raises: [ValueError].} =
  getBlockByTag(proxy, quantityTag).valueOr:
    raise newException(ValueError, "No block stored for given tag " & $quantityTag)

proc getBlockByHashOrThrow(
    proxy: VerifiedRpcProxy, blockHash: Hash32
): BlockObject {.raises: [ValueError].} =
  getBlockByHash(proxy, blockHash).valueOr:
    raise newException(ValueError, "No block stored for given hash " & $blockHash)

proc getBlockHeaderByTagOrThrow(
    proxy: VerifiedRpcProxy, quantityTag: BlockTag
): Header {.raises: [ValueError].} =
  let blk = getBlockByTag(proxy, quantityTag).valueOr:
    raise newException(ValueError, "No block stored for given tag " & $quantityTag)

  return Header(
    parentHash: blk.parentHash,
    ommersHash: blk.sha3Uncles,
    coinbase: blk.miner,
    stateRoot: blk.stateRoot,
    transactionsRoot: blk.transactionsRoot,
    receiptsRoot: blk.receiptsRoot,
    logsBloom: blk.logsBloom,
    difficulty: blk.difficulty,
    number: distinctBase(blk.number),
    gasLimit: distinctBase(blk.gasLimit),
    gasUsed: distinctBase(blk.gasUsed),
    timestamp: blk.timestamp.ethTime,
    extraData: distinctBase(blk.extraData),
    mixHash: Bytes32(distinctBase(blk.mixHash)),
    nonce: blk.nonce.get,
    baseFeePerGas: blk.baseFeePerGas,
    withdrawalsRoot: blk.withdrawalsRoot,
    blobGasUsed: blk.blobGasUsed.u64,
    excessBlobGas: blk.excessBlobGas.u64,
    parentBeaconBlockRoot: blk.parentBeaconBlockRoot,
    requestsHash: blk.requestsHash
  )

proc getBlockHeaderByHashOrThrow(
    proxy: VerifiedRpcProxy, blockHash: Hash32
): Header {.raises: [ValueError].} =
  let blk = getBlockByHash(proxy, blockHash).valueOr:
    raise newException(ValueError, "No block stored for given hash " & $blockHash)

  return Header(
    parentHash: blk.parentHash,
    ommersHash: blk.sha3Uncles,
    coinbase: blk.miner,
    stateRoot: blk.stateRoot,
    transactionsRoot: blk.transactionsRoot,
    receiptsRoot: blk.receiptsRoot,
    logsBloom: blk.logsBloom,
    difficulty: blk.difficulty,
    number: distinctBase(blk.number),
    gasLimit: distinctBase(blk.gasLimit),
    gasUsed: distinctBase(blk.gasUsed),
    timestamp: blk.timestamp.ethTime,
    extraData: distinctBase(blk.extraData),
    mixHash: Bytes32(distinctBase(blk.mixHash)),
    nonce: blk.nonce.get,
    baseFeePerGas: blk.baseFeePerGas,
    withdrawalsRoot: blk.withdrawalsRoot,
    blobGasUsed: blk.blobGasUsed.u64,
    excessBlobGas: blk.excessBlobGas.u64,
    parentBeaconBlockRoot: blk.parentBeaconBlockRoot,
    requestsHash: blk.requestsHash
  )

proc getAccount(lcProxy: VerifiedRpcProxy, address: Address, quantityTag: BlockTag): Future[Account] {.async: (raises: [ValueError, CatchableError]).} =
  let
    blk = lcProxy.getBlockByTagOrThrow(quantityTag)
    blockNumber = blk.number.uint64

  let
    proof = await lcProxy.rpcClient.eth_getProof(address, @[], blockId(blockNumber))
    account = getAccountFromProof(
      blk.stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
      proof.storageHash, proof.accountProof,
    ).valueOr:
      raise newException(ValueError, error)

  return account

proc getCode(lcProxy: VerifiedRpcProxy, address: Address, quantityTag: BlockTag): Future[seq[byte]] {.async: (raises: [ValueError, CatchableError]).} = 
  let
    blk = lcProxy.getBlockByTagOrThrow(quantityTag)
    blockNumber = blk.number.uint64
    account = await lcProxy.getAccount(address, quantityTag)
 
  info "Forwarding eth_getCode", blockNumber

  if account.codeHash == EMPTY_CODE_HASH:
    # account does not have any code, return empty hex data
    return @[]

  let code = await lcProxy.rpcClient.eth_getCode(address, blockId(blockNumber))

  if isValidCode(account, code):
    return code
  else:
    raise newException(ValueError, "received code doesn't match the account code hash")

proc getStorageAt(lcProxy: VerifiedRpcProxy, address: Address, slot: UInt256, quantityTag: BlockTag): Future[UInt256] {.async: (raises: [ValueError, CatchableError]).} = 
  let
    blk = lcProxy.getBlockByTagOrThrow(quantityTag)
    blockNumber = blk.number.uint64

  info "Forwarding eth_getStorageAt", blockNumber

  let 
    proof = await lcProxy.rpcClient.eth_getProof(address, @[slot], blockId(blockNumber))
    slotValue = getStorageData(blk.stateRoot, slot, proof).valueOr:
      raise newException(ValueError, error)

  slotValue

proc installEthApiHandlers*(lcProxy: VerifiedRpcProxy) =
  lcProxy.proxy.rpc("eth_chainId") do() -> UInt256:
    lcProxy.chainId

  lcProxy.proxy.rpc("eth_blockNumber") do() -> uint64:
    ## Returns the number of the most recent block.
    let latest = lcProxy.blockCache.latest.valueOr:
      raise newException(ValueError, "Syncing")

    latest.number.uint64

  lcProxy.proxy.rpc("eth_getBalance") do(
    address: Address, quantityTag: BlockTag
  ) -> UInt256:
    let account = await lcProxy.getAccount(address, quantityTag)
    account.balance

  lcProxy.proxy.rpc("eth_getStorageAt") do(
    address: Address, slot: UInt256, quantityTag: BlockTag
  ) -> UInt256:
    await lcProxy.getStorageAt(address, slot, quantityTag)

  lcProxy.proxy.rpc("eth_getTransactionCount") do(
    address: Address, quantityTag: BlockTag
  ) -> Quantity:
    let account = await lcProxy.getAccount(address, quantityTag)
    Quantity(account.nonce)

  lcProxy.proxy.rpc("eth_getCode") do(
    address: Address, quantityTag: BlockTag
  ) -> seq[byte]:
    await lcProxy.getCode(address, quantityTag)

  lcProxy.proxy.rpc("eth_call") do(
    args: TransactionArgs, quantityTag: BlockTag
  ) -> seq[byte]:

    # eth_call
    # 1. get the code with proof
    let to = if args.to.isSome(): args.to.get()
             else: raise newException(ValueError, "contract address missing in transaction args")

    # 2. get all storage locations that are accessed
    let 
      code = await lcProxy.getCode(to, quantityTag)
      header = lcProxy.getBlockHeaderByTagOrThrow(quantityTag)
      blkNumber = header.number.uint64
      parent = lcProxy.getBlockHeaderByHashOrThrow(header.parentHash)
      accessListResult = await lcProxy.rpcClient.eth_createAccessList(args, blockId(blkNumber)) 

    let accessList = if not accessListResult.error.isSome(): accessListResult.accessList
                     else: raise newException(ValueError, "couldn't get an access list for eth call")

    # 3. pull the storage values that are access along with their accounts and initialize db
    let 
      com = CommonRef.new(newCoreDbRef DefaultDbMemory, nil)
      fork = com.toEVMFork(header)
      vmState = BaseVMState()

    vmState.init(parent, header, com, com.db.baseTxFrame())
    vmState.mutateLedger:
      for accessPair in accessList:
        let 
          accountAddr = accessPair.address
          acc = await lcProxy.getAccount(accountAddr, quantityTag)
          accCode = await lcProxy.getCode(accountAddr, quantityTag)

        db.setNonce(accountAddr, acc.nonce)
        db.setBalance(accountAddr, acc.balance)
        db.setCode(accountAddr, accCode)

        for slot in accessPair.storageKeys:
          let slotInt = UInt256.fromHex(toHex(slot))
          let slotValue = await lcProxy.getStorageAt(accountAddr, slotInt, quantityTag) 
          db.setStorage(accountAddr, slotInt, slotValue)
      db.persist(clearEmptyAccount = false) # settle accounts storage

    # 4. run the evm with the initialized storage
    let evmResult = rpcCallEvm(args, header, vmState).valueOr:
      raise newException(ValueError, "rpcCallEvm error: " & $error.code)

    evmResult.output

  # TODO:
  # Following methods are forwarded directly to the web3 provider and therefore
  # are not validated in any way.
  lcProxy.proxy.registerProxyMethod("net_version")
  lcProxy.proxy.registerProxyMethod("eth_sendRawTransaction")
  lcProxy.proxy.registerProxyMethod("eth_getTransactionReceipt")

  # TODO currently we do not handle fullTransactions flag. It require updates on
  # nim-web3 side
  lcProxy.proxy.rpc("eth_getBlockByNumber") do(
    quantityTag: BlockTag, fullTransactions: bool
  ) -> Opt[BlockObject]:
    lcProxy.getBlockByTag(quantityTag)

  lcProxy.proxy.rpc("eth_getBlockByHash") do(
    blockHash: Hash32, fullTransactions: bool
  ) -> Opt[BlockObject]:
    lcProxy.blockCache.getPayloadByHash(blockHash)

proc new*(
    T: type VerifiedRpcProxy, proxy: RpcProxy, blockCache: BlockCache, chainId: UInt256
): T =
  VerifiedRpcProxy(proxy: proxy, blockCache: blockCache, chainId: chainId)

# Used to be in eth1_monitor.nim; not sure why it was deleted,
# so I copied it here. --Adam
template awaitWithRetries*[T](
    lazyFutExpr: Future[T], retries = 3, timeout = 60.seconds
): untyped =
  const reqType = astToStr(lazyFutExpr)
  var
    retryDelayMs = 16000
    f: Future[T]
    attempts = 0

  while true:
    f = lazyFutExpr
    yield f or sleepAsync(timeout)
    if not f.finished:
      await cancelAndWait(f)
    elif f.failed:
      when not (f.error of CatchableError):
        static:
          doAssert false, "f.error not CatchableError"
      debug "Web3 request failed", req = reqType, err = f.error.msg
    else:
      break

    inc attempts
    if attempts >= retries:
      var errorMsg = reqType & " failed " & $retries & " times"
      if f.failed:
        errorMsg &= ". Last error: " & f.error.msg
      raise newException(ValueError, errorMsg)

    await sleepAsync(chronos.milliseconds(retryDelayMs))
    retryDelayMs *= 2

  read(f)

proc verifyChaindId*(p: VerifiedRpcProxy): Future[void] {.async.} =
  let localId = p.chainId

  # retry 2 times, if the data provider fails despite the re-tries, propagate
  # exception to the caller.
  let providerId =
    awaitWithRetries(p.rpcClient.eth_chainId(), retries = 2, timeout = seconds(30))

  # This is a chain/network mismatch error between the Nimbus verified proxy and
  # the application using it. Fail fast to avoid misusage. The user must fix
  # the configuration.
  if localId != providerId:
    fatal "The specified data provider serves data for a different chain",
      expectedChain = localId, providerChain = providerId
    quit 1
