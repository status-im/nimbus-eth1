# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import results, stint, eth/common/addresses

const L2L1_MESSAGE_PASSER_CONTRACT* =
  address("0x4200000000000000000000000000000000000016")

type OpChainParams* = object
  opNetwork*: string
  l1Network*: string
  l1ChainId*: UInt256
  l2ChainId*: UInt256
  systemConfig*: Address

const opMainnet = OpChainParams(
  opNetwork: "op-mainnet",
  l1Network: "mainnet",
  l1ChainId: 1.u256,
  l2ChainId: 10.u256,
  systemConfig: address("0x229047fed2591dbec1eF1118d64F7aF3dB9EB290"),
)

const baseMainnet = OpChainParams(
  opNetwork: "base-mainnet",
  l1Network: "mainnet",
  l1ChainId: 1.u256,
  l2ChainId: 8453.u256,
  systemConfig: address("0x73a79Fab69143498Ed3712e519A88a918e1f4072"),
)

const opSepolia = OpChainParams(
  opNetwork: "op-sepolia",
  l1Network: "sepolia",
  l1ChainId: 11155111.u256,
  l2ChainId: 11155420.u256,
  systemConfig: address("0x034edD2A225f7f429A63E0f1D2084B9E0A93b538"),
)

func opChainParamsForNetwork*(name: string): Result[OpChainParams, string] =
  case name
  of "op-mainnet":
    ok(opMainnet)
  of "base-mainnet":
    ok(baseMainnet)
  of "op-sepolia":
    ok(opSepolia)
  else:
    err("unknown op-network preset: " & name)

func isOpNetwork*(name: string): bool =
  opChainParamsForNetwork(name).isOk()

func getSystemConfig*(chainId: UInt256): Result[Address, string] =
  for params in [opMainnet, baseMainnet, opSepolia]:
    if params.l2ChainId == chainId:
      return ok(params.systemConfig)
  err("unknown op  chainId: " & $chainId)

func opL1ChainId*(chainId: UInt256): Result[UInt256, string] =
  for params in [opMainnet, baseMainnet, opSepolia]:
    if params.l2ChainId == chainId:
      return ok(params.l1ChainId)
  err("unknown op  chainId: " & $chainId)
