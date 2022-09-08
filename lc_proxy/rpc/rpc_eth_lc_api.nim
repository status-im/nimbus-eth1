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
  json_rpc/[rpcserver, rpcclient],
  web3,
  web3/ethhexstrings,
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/spec/forks,
  ../validate_proof

export forks

logScope:
  topics = "light_proxy"

template encodeQuantity(value: UInt256): HexQuantityStr =
  hexQuantityStr("0x" & value.toHex())


template encodeHexData(value: UInt256): HexDataStr =
  hexDataStr("0x" & toBytesBe(value).toHex)

template encodeQuantity(value: Quantity): HexQuantityStr =
  hexQuantityStr(encodeQuantity(value.uint64))

type LightClientRpcProxy* = ref object
  client*: RpcClient
  server*: RpcHttpServer
  executionPayload*: Opt[ExecutionPayloadV1]


template checkPreconditions(payload: Opt[ExecutionPayloadV1], quantityTag: string) =
  if payload.isNone():
    raise newException(ValueError, "Syncing")

  if quantityTag != "latest":
    # TODO for now we support only latest block, as its semanticly most streight
    # forward i.e it is last received and valid ExecutionPayloadV1.
    # Ultimatly we could keep track of n last valid payload and support number
    # queries for this set of blocks
    # `Pending` coud be mapped to some optimisc header with block fetched on demand
    raise newException(ValueError, "Only latest block is supported")

proc installEthApiHandlers*(lcProxy: LightClientRpcProxy) =
  template payload(): Opt[ExecutionPayloadV1] = lcProxy.executionPayload

  lcProxy.server.rpc("eth_blockNumber") do() -> HexQuantityStr:
    ## Returns the number of most recent block.
    if payload.isNone:
      raise newException(ValueError, "Syncing")

    return encodeQuantity(payload.get.blockNumber)

  # TODO quantity tag should be better typed
  lcProxy.server.rpc("eth_getBalance") do(address: Address, quantityTag: string) -> HexQuantityStr:
    checkPreconditions(payload, quantityTag)

    # When requesting state for `latest` block number, we need to translate
    # `latest` to actual block number as `latest` on proxy and on data provider
    # can mean different blocks and ultimatly piece received piece of state
    # must by validated against correct state root
    let
      executionPayload = payload.get
      blockNumber = executionPayload.blockNumber.uint64

    info "Forwarding get_Balance", executionBn = blockNumber

    let proof = await lcProxy.client.eth_getProof(address, @[], blockId(blockNumber))

    let proofValid = isAccountProofValid(
      executionPayload.stateRoot,
      proof.address,
      proof.balance,
      proof.nonce,
      proof.codeHash,
      proof.storageHash,
      proof.accountProof
    )

    if proofValid:
      return encodeQuantity(proof.balance)
    else:
      raise newException(ValueError, "Data provided by data provider server is invalid")

  lcProxy.server.rpc("eth_getStorageAt") do(address: Address, slot: HexDataStr, quantityTag: string) -> HexDataStr:
    checkPreconditions(payload, quantityTag)

    let
      executionPayload = payload.get
      uslot = UInt256.fromHex(slot.string)
      blockNumber = executionPayload.blockNumber.uint64

    info "Forwarding eth_getStorageAt", executionBn = blockNumber

    let proof = await lcProxy.client.eth_getProof(address, @[uslot], blockId(blockNumber))

    let dataResult = getStorageData(executionPayload.stateRoot, uslot, proof)

    if dataResult.isOk():
      let slotValue = dataResult.get()
      return encodeHexData(slotValue)
    else:
      raise newException(ValueError, dataResult.error)
