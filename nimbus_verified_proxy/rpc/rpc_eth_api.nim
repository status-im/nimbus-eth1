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
  stew/byteutils,
  json_rpc/[rpcserver, rpcclient, rpcproxy],
  eth/common/[accounts, headers],
  web3/eth_api,
  ../validate_proof,
  ../block_cache,
  ../../fluffy/evm/async_evm

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

proc getBlockByTagOrThrow(
    proxy: VerifiedRpcProxy, quantityTag: BlockTag
): BlockObject {.raises: [ValueError].} =
  getBlockByTag(proxy, quantityTag).valueOr:
    raise newException(ValueError, "No block stored for given tag " & $quantityTag)

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
    # When requesting state for `latest` block number, we need to translate
    # `latest` to actual block number as `latest` on proxy and on data provider
    # can mean different blocks and ultimatly piece received piece of state
    # must by validated against correct state root
    let
      blk = lcProxy.getBlockByTagOrThrow(quantityTag)
      blockNumber = blk.number.uint64

    info "Forwarding eth_getBalance call", blockNumber

    let
      proof = await lcProxy.rpcClient.eth_getProof(address, @[], blockId(blockNumber))
      account = getAccountFromProof(
        blk.stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
        proof.storageHash, proof.accountProof,
      ).valueOr:
        raise newException(ValueError, error)

    account.balance

  lcProxy.proxy.rpc("eth_getStorageAt") do(
    address: Address, slot: UInt256, quantityTag: BlockTag
  ) -> UInt256:
    let
      blk = lcProxy.getBlockByTagOrThrow(quantityTag)
      blockNumber = blk.number.uint64

    info "Forwarding eth_getStorageAt", blockNumber

    let proof =
      await lcProxy.rpcClient.eth_getProof(address, @[slot], blockId(blockNumber))

    getStorageData(blk.stateRoot, slot, proof).valueOr:
      raise newException(ValueError, error)

  lcProxy.proxy.rpc("eth_getTransactionCount") do(
    address: Address, quantityTag: BlockTag
  ) -> uint64:
    let
      blk = lcProxy.getBlockByTagOrThrow(quantityTag)
      blockNumber = blk.number.uint64

    info "Forwarding eth_getTransactionCount", blockNumber

    let
      proof = await lcProxy.rpcClient.eth_getProof(address, @[], blockId(blockNumber))

      account = getAccountFromProof(
        blk.stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
        proof.storageHash, proof.accountProof,
      ).valueOr:
        raise newException(ValueError, error)

    account.nonce

  lcProxy.proxy.rpc("eth_getCode") do(
    address: Address, quantityTag: BlockTag
  ) -> seq[byte]:
    let
      blk = lcProxy.getBlockByTagOrThrow(quantityTag)
      blockNumber = blk.number.uint64

    info "Forwarding eth_getCode", blockNumber
    let
      proof = await lcProxy.rpcClient.eth_getProof(address, @[], blockId(blockNumber))
      account = getAccountFromProof(
        blk.stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
        proof.storageHash, proof.accountProof,
      ).valueOr:
        raise newException(ValueError, error)

    if account.codeHash == EMPTY_CODE_HASH:
      # account does not have any code, return empty hex data
      return @[]

    let code = await lcProxy.rpcClient.eth_getCode(address, blockId(blockNumber))

    if isValidCode(account, code):
      return code
    else:
      raise newException(
        ValueError, "Received code which does not match the account code hash"
      )

  # TODO:
  # Following methods are forwarded directly to the web3 provider and therefore
  # are not validated in any way.
  lcProxy.proxy.registerProxyMethod("net_version")

  # lcProxy.proxy.registerProxyMethod("eth_call")

  lcProxy.proxy.rpc("eth_call") do(args: TransactionArgs, blockTag: BlockTag) -> seq[byte]:
    # let tag = parseQuantityTag(quantityTag).valueOr:
    #   raise newException(ValueError, error)

    let blk = await lcProxy.rpcClient.eth_getBlockByNumber(blockTag, false)
    let blockNumber = blk.number.uint64
    echo "blockNumber: ", blockNumber
    let accProc = proc(stateRoot: Hash32, address: Address): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
      try:
        let balance = await lcProxy.rpcClient.eth_getBalance(address, blockId(blockNumber))
        let nonce = await lcProxy.rpcClient.eth_getTransactionCount(address, blockId(blockNumber))
        let account = Account.init(balance = balance, nonce = distinctBase(nonce))
        # let
        #   proof = await lcProxy.rpcClient.eth_getProof(address, @[], blockId(blockNumber))
        #   account = getAccountFromProof(blk.stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash, proof.storageHash, proof.accountProof).valueOr:
        #     raise newException(ValueError, "Failed to find account proof")
        echo "fetched account: ", address
        Opt.some(account)
      except CatchableError as e:
        echo "shouldn't fail: " & e.msg
        Opt.none(Account)

    let storageProc = proc(stateRoot: Hash32, address: Address, slotKey: UInt256): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
      try:
        let slot = await lcProxy.rpcClient.eth_getStorageAt(address, slotKey, blockId(blockNumber))

        # let slot = getStorageData(blk.stateRoot, slotKey, proof).valueOr:
        #   raise newException(ValueError, error)
        echo "fetched slot: ", address, " ", UInt256.fromBytesBE(slot.data)
        Opt.some(UInt256.fromBytesBE(slot.data))
      except CatchableError as e:
        echo "shouldn't fail: " & e.msg
        Opt.none(UInt256)

    let codeProc = proc(stateRoot: Hash32, address: Address): Future[Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
      try:
        let code = await lcProxy.rpcClient.eth_getCode(address, blockId(blockNumber))
        echo "fetched code at: ", address
        Opt.some(code)
      except CatchableError as e:
        echo "shouldn't fail: " & e.msg
        Opt.none(seq[byte])

    let backend = AsyncEvmStateBackend.init(accProc, storageProc, codeProc)
    let asyncEvm = AsyncEvm.init(backend)

    #let header = Header(stateRoot: blk.stateRoot, number: blockNumber)
    let header = blk.toHeader()
    let callResult = (await asyncEvm.call(header, args, true)).valueOr:
      raise newException(ValueError, error)

    return callResult.output

  lcProxy.proxy.rpc("eth_createAccessList") do(args: TransactionArgs, blockTag: BlockTag) -> AccessListResult:
    # let tag = parseQuantityTag(quantityTag).valueOr:
    #   raise newException(ValueError, error)

    let blk = await lcProxy.rpcClient.eth_getBlockByNumber(blockTag, false)
    let blockNumber = blk.number.uint64
    echo "blockNumber: ", blockNumber
    let accProc = proc(stateRoot: Hash32, address: Address): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
      try:
        let balance = await lcProxy.rpcClient.eth_getBalance(address, blockId(blockNumber))
        let nonce = await lcProxy.rpcClient.eth_getTransactionCount(address, blockId(blockNumber))
        let account = Account.init(balance = balance, nonce = distinctBase(nonce))
        # let
        #   proof = await lcProxy.rpcClient.eth_getProof(address, @[], blockId(blockNumber))
        #   account = getAccountFromProof(blk.stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash, proof.storageHash, proof.accountProof).valueOr:
        #     raise newException(ValueError, "Failed to find account proof")
        echo "fetched account: ", address
        Opt.some(account)
      except CatchableError as e:
        echo "shouldn't fail: " & e.msg
        Opt.none(Account)

    let storageProc = proc(stateRoot: Hash32, address: Address, slotKey: UInt256): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
      try:
        let slot = await lcProxy.rpcClient.eth_getStorageAt(address, slotKey, blockId(blockNumber))

        # let slot = getStorageData(blk.stateRoot, slotKey, proof).valueOr:
        #   raise newException(ValueError, error)
        echo "fetched slot: ", address, " ", UInt256.fromBytesBE(slot.data)
        Opt.some(UInt256.fromBytesBE(slot.data))
      except CatchableError as e:
        echo "shouldn't fail: " & e.msg
        Opt.none(UInt256)

    let codeProc = proc(stateRoot: Hash32, address: Address): Future[Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
      try:
        let code = await lcProxy.rpcClient.eth_getCode(address, blockId(blockNumber))
        echo "fetched code at: ", address
        Opt.some(code)
      except CatchableError as e:
        echo "shouldn't fail: " & e.msg
        Opt.none(seq[byte])

    let backend = AsyncEvmStateBackend.init(accProc, storageProc, codeProc)
    let asyncEvm = AsyncEvm.init(backend)
    let header = blk.toHeader()
    let (accessList, gasUsed) = (
      await asyncEvm.createAccessList(header, args, true)
    ).valueOr:
      raise newException(ValueError, error)

    return AccessListResult(accessList: accessList, gasUsed: gasUsed.Quantity)



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
