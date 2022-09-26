# ligh client proxy
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/strutils,
  stint,
  stew/[byteutils, results],
  chronicles,
  json_rpc/[rpcproxy, rpcserver, rpcclient],
  web3,
  web3/[ethhexstrings, ethtypes],
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/forks,
  ../validate_proof,
  ../block_cache

export forks

logScope:
  topics = "light_proxy"

proc `==`(x, y: Quantity): bool {.borrow, noSideEffect.}

template encodeQuantity(value: UInt256): HexQuantityStr =
  hexQuantityStr("0x" & value.toHex())

template encodeHexData(value: UInt256): HexDataStr =
  hexDataStr("0x" & toBytesBE(value).toHex)

template encodeQuantity(value: Quantity): HexQuantityStr =
  hexQuantityStr(encodeQuantity(value.uint64))

type
  LightClientRpcProxy* = ref object
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
    return err("Invalid Etheruem Hex quantity.")

func parseQuantityTag(blockTag: string): Result[QuantityTag, string] =
  let tag = blockTag.toLowerAscii
  case tag
  of "latest":
    return ok(QuantityTag(kind: LatestBlock))
  else:
    let quantity = ? parseHexQuantity(tag)
    return ok(QuantityTag(kind: BlockNumber, blockNumber: quantity))

template checkPreconditions(proxy: LightClientRpcProxy) =
  if proxy.blockCache.isEmpty():
    raise newException(ValueError, "Syncing")

template rpcClient(lcProxy: LightClientRpcProxy): RpcClient = lcProxy.proxy.getClient()

proc getPayloadByTag(
    proxy: LightClientRpcProxy,
    quantityTag: string): ExecutionPayloadV1 {.raises: [ValueError, Defect].} =
  checkPreconditions(proxy)

  let tagResult = parseQuantityTag(quantityTag)

  if tagResult.isErr:
    raise newException(ValueError, tagResult.error)

  let tag = tagResult.get()

  var payload: ExecutionPayloadV1

  case tag.kind
  of LatestBlock:
    # this will always be ok as we always validate that cache is not empty
    payload = proxy.blockCache.latest.get
  of BlockNumber:
    let payLoadResult = proxy.blockCache.getByNumber(tag.blockNumber)
    if payLoadResult.isErr():
      raise newException(ValueError, "Unknown block with number " & $tag.blockNumber)
    payload = payLoadResult.get

  return payload

proc installEthApiHandlers*(lcProxy: LightClientRpcProxy) =
  template payload(): Opt[ExecutionPayloadV1] = lcProxy.executionPayload

  lcProxy.proxy.rpc("eth_chainId") do() -> HexQuantityStr:
    return encodeQuantity(lcProxy.chainId)

  lcProxy.proxy.rpc("eth_blockNumber") do() -> HexQuantityStr:
    ## Returns the number of most recent block.
    checkPreconditions(lcProxy)

    return encodeQuantity(lcProxy.blockCache.latest.get.blockNumber)

  lcProxy.proxy.rpc("eth_getBalance") do(address: Address, quantityTag: string) -> HexQuantityStr:
    # When requesting state for `latest` block number, we need to translate
    # `latest` to actual block number as `latest` on proxy and on data provider
    # can mean different blocks and ultimatly piece received piece of state
    # must by validated against correct state root
    let
      executionPayload = lcProxy.getPayloadByTag(quantityTag)
      blockNumber = executionPayload.blockNumber.uint64

    info "Forwarding get_Balance", executionBn = blockNumber

    let proof = await lcProxy.rpcClient.eth_getProof(address, @[], blockId(blockNumber))

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

  lcProxy.proxy.rpc("eth_getStorageAt") do(address: Address, slot: HexDataStr, quantityTag: string) -> HexDataStr:
    let
      executionPayload = lcProxy.getPayloadByTag(quantityTag)
      uslot = UInt256.fromHex(slot.string)
      blockNumber = executionPayload.blockNumber.uint64

    info "Forwarding eth_getStorageAt", executionBn = blockNumber

    let proof = await lcProxy.rpcClient.eth_getProof(address, @[uslot], blockId(blockNumber))

    let dataResult = getStorageData(executionPayload.stateRoot, uslot, proof)

    if dataResult.isOk():
      let slotValue = dataResult.get()
      return encodeHexData(slotValue)
    else:
      raise newException(ValueError, dataResult.error)

  # TODO This methods are forwarded directly to provider therefore thay are not
  # validated in any way
  lcProxy.proxy.registerProxyMethod("net_version")
  lcProxy.proxy.registerProxyMethod("eth_call")

  # TODO cache blocks received from light client, and respond using them in this
  # call. It would also enable handling of numerical `quantityTag` for the
  # set of cached blocks
  lcProxy.proxy.registerProxyMethod("eth_getBlockByNumber")

proc new*(
    T: type LightClientRpcProxy,
    proxy: RpcProxy,
    blockCache: BlockCache,
    chainId: Quantity): T =

  return LightClientRpcProxy(
    proxy: proxy,
    blockCache: blockCache,
    chainId: chainId
  )

proc verifyChaindId*(p: LightClientRpcProxy): Future[void] {.async.} =
  let localId = p.chainId

  # retry 2 times, if the data provider will fail despite re-tries, propagate
  # exception to the caller.
  let providerId = awaitWithRetries(
    p.rpcClient.eth_chainId(),
    retries = 2,
    timeout = seconds(30)
  )

  # this configuration error, in theory we could allow proxy to chung on, but
  # it would only mislead the user. It is better to fail fast here.
  if localId != providerId:
    fatal "The specified data provider serves data for a different chain",
      expectedChain = distinctBase(localId),
      providerChain = distinctBase(providerId)
    quit 1

  return

