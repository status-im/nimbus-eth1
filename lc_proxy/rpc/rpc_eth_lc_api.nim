# beacon_chain
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_rpc/[rpcproxy, rpcserver],
  web3/conversions,
  ../../nimbus/rpc/[hexstrings, rpc_types],
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/spec/forks

export rpcproxy, forks

template encodeQuantity(value: UInt256): HexQuantityStr =
  HexQuantityStr("0x" & value.toHex())

proc encodeQuantity(q: Quantity): hexstrings.HexQuantityStr =
  return hexstrings.encodeQuantity(distinctBase(q))

type LightClientRpcProxy* = ref object
  proxy*: RpcProxy
  executionPayload*: Opt[ExecutionPayloadV1]

proc installEthApiHandlers*(lcProxy: LightClientRpcProxy) =
  template payload(): Opt[ExecutionPayloadV1] = lcProxy.executionPayload

  lcProxy.proxy.rpc("eth_blockNumber") do() -> HexQuantityStr:
    ## Returns the number of most recent block.
    if payload.isNone:
      raise newException(ValueError, "Syncing")

    return encodeQuantity(payload.get.blockNumber)

  lcProxy.proxy.rpc("eth_getBlockByNumber") do(
      quantityTag: string, fullTransactions: bool) -> Option[rpc_types.BlockObject]:
    ## Returns information about a block by number.
    if payload.isNone:
      raise newException(ValueError, "Syncing")

    if quantityTag != "latest":
      raise newException(ValueError, "Only latest block is supported")

    if fullTransactions:
      raise newException(ValueError, "Transaction bodies not supported")

    return some rpc_types.BlockObject(number: some(encodeQuantity(payload.get.blockNumber)))
