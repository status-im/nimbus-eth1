# beacon_chain
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  stint,
  chronicles,
  json_rpc/[rpcserver, rpcclient],
  web3,
  web3/ethhexstrings,
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/spec/forks

export forks

logScope:
  topics = "light_proxy"

template encodeQuantity(value: UInt256): HexQuantityStr =
  hexQuantityStr("0x" & value.toHex())

template encodeQuantity(value: Quantity): HexQuantityStr =
  hexQuantityStr(encodeQuantity(value.uint64))

type LightClientRpcProxy* = ref object
  client*: RpcClient
  server*: RpcHttpServer
  executionPayload*: Opt[ExecutionPayloadV1]

proc installEthApiHandlers*(lcProxy: LightClientRpcProxy) =
  template payload(): Opt[ExecutionPayloadV1] = lcProxy.executionPayload

  lcProxy.server.rpc("eth_blockNumber") do() -> HexQuantityStr:
    ## Returns the number of most recent block.
    if payload.isNone:
      raise newException(ValueError, "Syncing")

    return encodeQuantity(payload.get.blockNumber)

  # TODO quantity tag should be better typed
  lcProxy.server.rpc("eth_getBalance") do(address: Address, quantityTag: string) -> HexQuantityStr:
    if payload.isNone:
      raise newException(ValueError, "Syncing")

    if quantityTag != "latest":
      # TODO for now we support only latest block, as its semanticly most streight
      # forward i.e it is last received and valid ExecutionPayloadV1.
      # Ultimatly we could keep track of n last valid payload and support number
      # queries for this set of blocks
      # `Pending` coud be mapped to some optimisc header with block fetched on demand
      raise newException(ValueError, "Only latest block is supported")

    # When requesting state for `latest` block number, we need to translate
    # `latest` to actual block number as `latest` on proxy and on data provider
    # can mean different blocks and ultimatly piece received piece of state
    # must by validated against correct state root
    let blockNumber = payload.get.blockNumber.uint64

    info "Forwarding get_Balance", executionBn = blockNumber

    # TODO this could be realised by eth_getProof as it return also balance
    # of the account
    let b = await lcProxy.client.eth_getBalance(address, blockId(blockNumber))

    return encodeQuantity(b)
