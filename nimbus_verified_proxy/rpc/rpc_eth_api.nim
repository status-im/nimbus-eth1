# nimbus_verified_proxy
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/strutils,
  stint,
  stew/[byteutils, results],
  chronicles,
  json_rpc/[rpcproxy, rpcserver, rpcclient],
  eth/common/eth_types as etypes,
  web3,
  web3/[ethhexstrings, ethtypes],
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/forks,
  ./rpc_utils,
  ../validate_proof,
  ../block_cache

export forks

logScope:
  topics = "verified_proxy"

proc `==`(x, y: Quantity): bool {.borrow, noSideEffect.}

template encodeQuantity(value: UInt256): HexQuantityStr =
  hexQuantityStr("0x" & value.toHex())

template encodeHexData(value: UInt256): HexDataStr =
  hexDataStr("0x" & toBytesBE(value).toHex)

template bytesToHex(bytes: seq[byte]): HexDataStr =
  hexDataStr("0x" & toHex(bytes))

template encodeQuantity(value: Quantity): HexQuantityStr =
  hexQuantityStr(encodeQuantity(value.uint64))

type
  VerifiedRpcProxy* = ref object
    proxy: RpcProxy
    blockCache: BlockCache
    chainId: Quantity

  QuantityTagKind = enum
    LatestBlock, BlockNumber

  QuantityTag = object
    case kind: QuantityTagKind
    of LatestBlock:
      discard
    of BlockNumber:
      blockNumber: Quantity

func parseHexIntResult(tag: string): Result[uint64, string] =
  try:
    ok(parseHexInt(tag).uint64)
  except ValueError as e:
    err(e.msg)

func parseHexQuantity(tag: string): Result[Quantity, string] =
  let hexQuantity = hexQuantityStr(tag)
  if validate(hexQuantity):
    let parsed = ? parseHexIntResult(tag)
    return ok(Quantity(parsed))
  else:
    return err("Invalid hex quantity.")

func parseQuantityTag(blockTag: string): Result[QuantityTag, string] =
  let tag = blockTag.toLowerAscii
  case tag
  of "latest":
    return ok(QuantityTag(kind: LatestBlock))
  else:
    let quantity = ? parseHexQuantity(tag)
    return ok(QuantityTag(kind: BlockNumber, blockNumber: quantity))

template checkPreconditions(proxy: VerifiedRpcProxy) =
  if proxy.blockCache.isEmpty():
    raise newException(ValueError, "Syncing")

template rpcClient(lcProxy: VerifiedRpcProxy): RpcClient =
  lcProxy.proxy.getClient()

proc getPayloadByTag(
    proxy: VerifiedRpcProxy,
    quantityTag: string):
    results.Opt[ExecutionData] {.raises: [ValueError].} =
  checkPreconditions(proxy)

  let tagResult = parseQuantityTag(quantityTag)

  if tagResult.isErr:
    raise newException(ValueError, tagResult.error)

  let tag = tagResult.get()

  case tag.kind
  of LatestBlock:
    # this will always return some block, as we always checkPreconditions
    return proxy.blockCache.latest
  of BlockNumber:
    return proxy.blockCache.getByNumber(tag.blockNumber)

proc getPayloadByTagOrThrow(
    proxy: VerifiedRpcProxy,
    quantityTag: string): ExecutionData {.raises: [ValueError].} =

  let tagResult = getPayloadByTag(proxy, quantityTag)

  if tagResult.isErr:
    raise newException(ValueError, "No block stored for given tag " & quantityTag)

  return tagResult.get()

proc installEthApiHandlers*(lcProxy: VerifiedRpcProxy) =
  lcProxy.proxy.rpc("eth_chainId") do() -> HexQuantityStr:
    return encodeQuantity(lcProxy.chainId)

  lcProxy.proxy.rpc("eth_blockNumber") do() -> HexQuantityStr:
    ## Returns the number of the most recent block.
    checkPreconditions(lcProxy)

    return encodeQuantity(lcProxy.blockCache.latest.get.blockNumber)

  lcProxy.proxy.rpc("eth_getBalance") do(
      address: Address, quantityTag: string) -> HexQuantityStr:
    # When requesting state for `latest` block number, we need to translate
    # `latest` to actual block number as `latest` on proxy and on data provider
    # can mean different blocks and ultimatly piece received piece of state
    # must by validated against correct state root
    let
      executionPayload = lcProxy.getPayloadByTagOrThrow(quantityTag)
      blockNumber = executionPayload.blockNumber.uint64

    info "Forwarding eth_getBalance call", blockNumber

    let proof = await lcProxy.rpcClient.eth_getProof(
      address, @[], blockId(blockNumber))

    let accountResult = getAccountFromProof(
      executionPayload.stateRoot,
      proof.address,
      proof.balance,
      proof.nonce,
      proof.codeHash,
      proof.storageHash,
      proof.accountProof
    )

    if accountResult.isOk():
      return encodeQuantity(accountResult.get.balance)
    else:
      raise newException(ValueError, accountResult.error)

  lcProxy.proxy.rpc("eth_getStorageAt") do(
      address: Address, slot: HexDataStr, quantityTag: string) -> HexDataStr:
    let
      executionPayload = lcProxy.getPayloadByTagOrThrow(quantityTag)
      uslot = UInt256.fromHex(slot.string)
      blockNumber = executionPayload.blockNumber.uint64

    info "Forwarding eth_getStorageAt", blockNumber

    let proof = await lcProxy.rpcClient.eth_getProof(
      address, @[uslot], blockId(blockNumber))

    let dataResult = getStorageData(executionPayload.stateRoot, uslot, proof)

    if dataResult.isOk():
      let slotValue = dataResult.get()
      return encodeHexData(slotValue)
    else:
      raise newException(ValueError, dataResult.error)

  lcProxy.proxy.rpc("eth_getTransactionCount") do(
      address: Address, quantityTag: string) -> HexQuantityStr:
    let
      executionPayload = lcProxy.getPayloadByTagOrThrow(quantityTag)
      blockNumber = executionPayload.blockNumber.uint64

    info "Forwarding eth_getTransactionCount", blockNumber

    let proof = await lcProxy.rpcClient.eth_getProof(
      address, @[], blockId(blockNumber))

    let accountResult = getAccountFromProof(
      executionPayload.stateRoot,
      proof.address,
      proof.balance,
      proof.nonce,
      proof.codeHash,
      proof.storageHash,
      proof.accountProof
    )

    if accountResult.isOk():
      return hexQuantityStr(encodeQuantity(accountResult.get.nonce))
    else:
      raise newException(ValueError, accountResult.error)

  lcProxy.proxy.rpc("eth_getCode") do(
      address: Address, quantityTag: string) -> HexDataStr:
    let
      executionPayload = lcProxy.getPayloadByTagOrThrow(quantityTag)
      blockNumber = executionPayload.blockNumber.uint64

    let
      proof = await lcProxy.rpcClient.eth_getProof(
        address, @[], blockId(blockNumber))
      accountResult = getAccountFromProof(
        executionPayload.stateRoot,
        proof.address,
        proof.balance,
        proof.nonce,
        proof.codeHash,
        proof.storageHash,
        proof.accountProof
      )

    if accountResult.isErr():
      raise newException(ValueError, accountResult.error)

    let account = accountResult.get()

    if account.codeHash == etypes.EMPTY_CODE_HASH:
      # account does not have any code, return empty hex data
      return hexDataStr("0x")

    info "Forwarding eth_getCode", blockNumber

    let code = await lcProxy.rpcClient.eth_getCode(
      address,
      blockId(blockNumber)
    )

    if isValidCode(account, code):
      return bytesToHex(code)
    else:
      raise newException(ValueError,
        "Received code which does not match the account code hash")

  # TODO:
  # Following methods are forwarded directly to the web3 provider and therefore
  # are not validated in any way.
  lcProxy.proxy.registerProxyMethod("net_version")
  lcProxy.proxy.registerProxyMethod("eth_call")
  lcProxy.proxy.registerProxyMethod("eth_sendRawTransaction")
  lcProxy.proxy.registerProxyMethod("eth_getTransactionReceipt")

  # TODO currently we do not handle fullTransactions flag. It require updates on
  # nim-web3 side
  lcProxy.proxy.rpc("eth_getBlockByNumber") do(
      quantityTag: string, fullTransactions: bool) -> Option[BlockObject]:
    let executionPayload = lcProxy.getPayloadByTag(quantityTag)

    if executionPayload.isErr:
      return none(BlockObject)

    return some(asBlockObject(executionPayload.get()))

  lcProxy.proxy.rpc("eth_getBlockByHash") do(
      blockHash: BlockHash, fullTransactions: bool) -> Option[BlockObject]:
    let executionPayload = lcProxy.blockCache.getPayloadByHash(blockHash)

    if executionPayload.isErr:
      return none(BlockObject)

    return some(asBlockObject(executionPayload.get()))

proc new*(
    T: type VerifiedRpcProxy,
    proxy: RpcProxy,
    blockCache: BlockCache,
    chainId: Quantity): T =
  VerifiedRpcProxy(
    proxy: proxy,
    blockCache: blockCache,
    chainId: chainId)

proc verifyChaindId*(p: VerifiedRpcProxy): Future[void] {.async.} =
  let localId = p.chainId

  # retry 2 times, if the data provider fails despite the re-tries, propagate
  # exception to the caller.
  let providerId = awaitWithRetries(
    p.rpcClient.eth_chainId(),
    retries = 2,
    timeout = seconds(30)
  )

  # This is a chain/network mismatch error between the Nimbus verified proxy and
  # the application using it. Fail fast to avoid misusage. The user must fix
  # the configuration.
  if localId != providerId:
    fatal "The specified data provider serves data for a different chain",
      expectedChain = distinctBase(localId),
      providerChain = distinctBase(providerId)
    quit 1

  return

