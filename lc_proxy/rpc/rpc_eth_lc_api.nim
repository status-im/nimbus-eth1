# ligh client proxy
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  stint,
  stew/byteutils,
  chronicles,
  json_rpc/[rpcproxy, rpcserver, rpcclient],
  web3,
  web3/[ethhexstrings, ethtypes],
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/forks,
  ../validate_proof

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

type LightClientRpcProxy* = ref object
  proxy: RpcProxy
  executionPayload*: Opt[ExecutionPayloadV1]
  chainId: Quantity

template checkPreconditions(payload: Opt[ExecutionPayloadV1], quantityTag: string) =
  if payload.isNone():
    raise newException(ValueError, "Syncing")

  if quantityTag != "latest":
    # TODO: for now we support only latest block, as its semantically most straight
    # forward, i.e it is last received and a valid ExecutionPayloadV1.
    # Ultimately we could keep track of n last valid payloads and support number
    # queries for this set of blocks.
    # `Pending` could be mapped to some optimistic header with the block
    # fetched on demand.
    raise newException(ValueError, "Only latest block is supported")

template rpcClient(lcProxy: LightClientRpcProxy): RpcClient = lcProxy.proxy.getClient()

proc installEthApiHandlers*(lcProxy: LightClientRpcProxy) =
  template payload(): Opt[ExecutionPayloadV1] = lcProxy.executionPayload

  lcProxy.proxy.rpc("eth_chainId") do() -> HexQuantityStr:
    return encodeQuantity(lcProxy.chainId)

  lcProxy.proxy.rpc("eth_blockNumber") do() -> HexQuantityStr:
    ## Returns the number of most recent block.
    if payload.isNone:
      raise newException(ValueError, "Syncing")

    return encodeQuantity(payload.get.blockNumber)

  # TODO quantity tag should be better typed
  lcProxy.proxy.rpc("eth_getBalance") do(address: Address, quantityTag: string) -> HexQuantityStr:
    checkPreconditions(payload, quantityTag)

    # When requesting state for `latest` block number, we need to translate
    # `latest` to actual block number as `latest` on proxy and on data provider
    # can mean different blocks and ultimatly piece received piece of state
    # must by validated against correct state root
    let
      executionPayload = payload.get
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
    checkPreconditions(payload, quantityTag)

    let
      executionPayload = payload.get
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
    chainId: Quantity): T =

  return LightClientRpcProxy(
    proxy: proxy,
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

